/// 单块在线字幕任务：用已通过字幕能力验证的在线语音配置生成可逐句播放的字幕。
///
/// 流水线：16 kHz WAV 转码 → 单块范围校验 → 一次文件转写请求（`verbose_json`
/// 片段时间戳，已确认支持的配置才请求词时间戳）→ 完整句还原与可选短句合并 →
/// 模型词时间戳逐句核对（对不上的句子用合成词时间戳）→ 经既有安全提交边界整体
/// 写入字幕与元数据 → 成功后才刷新内存状态。
///
/// 这里只做单块：超出单块范围直接失败，不截断、不发超限请求，长材料分块由后续
/// 切片负责。失败、取消、并发导入冲突都不写库，保留用户已有字幕。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:universal_io/io.dart';
import 'package:uuid/uuid.dart';

import '../database/daos/audio_item_dao.dart';
import '../database/providers.dart';
import '../models/audio_item.dart';
import '../models/recognition_selection.dart';
import '../services/app_logger.dart';
import '../services/asr/offline_asr_engine.dart' show AsrSegment;
import '../services/speech/speech_capability.dart';
import '../services/speech/speech_transcription_client.dart';
import '../services/subtitle_parser.dart';
import '../utils/model_word_timestamps.dart';
import '../utils/srt_generator.dart';
import '../utils/transcript_stats.dart';
import '../models/word_timestamp.dart';
import 'audio_library_provider.dart';
import 'local_transcription_task_provider.dart'
    show
        localTranscriptionTranscodeServiceProvider,
        mergeShortAsrSegments,
        restoreAsrSentences,
        transcriptionFileOpsProvider;
import 'recognition_settings_provider.dart';
import 'speech_capability_provider.dart';
import 'speech_configuration_provider.dart';

/// 单块音频时长上限：约两分钟。
///
/// 这是实施参数，不是用户可见选项：同时满足单次上传大小与供应商处理时限。
const onlineSubtitleMaxDuration = Duration(minutes: 2);

/// 单块上传字节上限（16 kHz 单声道 16 bit WAV 两分钟约 3.84 MB，留出请求余量）。
const onlineSubtitleMaxUploadBytes = 4 * 1024 * 1024;

/// 单块 WAV 的字节率：16 kHz × 16 bit × 单声道。
const _pcmWavBytesPerSecond = 16000 * 2;

/// 在线字幕失败的本地原因；供应商失败另由 [OnlineSubtitleFailed.speechError] 表达。
enum OnlineSubtitleFailureReason {
  /// 尚未保存在线语音服务地址或 Key。
  notConfigured,

  /// 当前配置没有通过字幕（片段时间戳）能力验证。
  notVerified,

  /// 音频超出单块范围，未截断也未发送请求。
  audioTooLong,

  /// 音频无法解码为可上传的 WAV。
  decodeFailed,

  /// 供应商返回的文本或片段通不过校验。
  invalidResult,

  /// 请求期间语音配置已变化，结果属于旧配置，不写入。
  configChanged,

  /// 其他未分类失败。
  unknown,
}

/// 在线字幕任务状态基类；Map 中缺少条目即为空闲。
sealed class OnlineSubtitleTaskState {
  const OnlineSubtitleTaskState();
}

/// 正在准备上传：转码、读取配置与凭据。
class OnlineSubtitlePreparing extends OnlineSubtitleTaskState {
  const OnlineSubtitlePreparing({required this.service, required this.modelId});

  /// 当前服务（预设名称或自定义），用于界面提示。
  final String service;

  /// 本次使用的在线模型 ID。
  final String modelId;
}

/// 已发出转写请求，等待供应商返回。
class OnlineSubtitleUploading extends OnlineSubtitleTaskState {
  const OnlineSubtitleUploading({required this.service, required this.modelId});

  final String service;
  final String modelId;
}

/// 字幕已整体落库。
class OnlineSubtitleCompleted extends OnlineSubtitleTaskState {
  const OnlineSubtitleCompleted({
    required this.modelId,
    required this.wordTimingSource,
    this.reportedCost,
  });

  final String modelId;

  /// 整份字幕的词时间戳来源，供界面如实提示。
  final TranscriptWordTimingSource wordTimingSource;

  /// 供应商报告的费用；null 表示未知，不能显示成免费。
  final double? reportedCost;
}

/// 本次失败，未写入任何字幕。[speechError] 非空时为供应商错误分类。
class OnlineSubtitleFailed extends OnlineSubtitleTaskState {
  const OnlineSubtitleFailed(this.reason, {this.speechError});

  final OnlineSubtitleFailureReason reason;
  final SpeechTranscriptionException? speechError;
}

/// 提交时发现目标字幕已被用户导入或编辑替换：保留用户较新的结果。
class OnlineSubtitleConflict extends OnlineSubtitleTaskState {
  const OnlineSubtitleConflict();
}

/// 在线字幕任务管理器。
///
/// 任务由全局 provider 持有：弹窗关闭后请求继续，重新打开仍能看到进度与结果。
/// 同一材料同时只允许一个在途任务，重复启动被忽略。
final onlineSubtitleTaskManagerProvider =
    NotifierProvider<OnlineSubtitleTaskManager, Map<String, OnlineSubtitleTaskState>>(
      OnlineSubtitleTaskManager.new,
    );

/// 维护在线字幕任务状态，并保证只有完整成功的结果会写库。
class OnlineSubtitleTaskManager
    extends Notifier<Map<String, OnlineSubtitleTaskState>> {
  final Set<String> _cancelled = {};
  final Map<String, CancelToken> _cancelTokens = {};
  final _uuid = const Uuid();

  @override
  Map<String, OnlineSubtitleTaskState> build() => {};

  /// 获取指定材料的在线任务状态。
  OnlineSubtitleTaskState? taskState(String audioId) => state[audioId];

  /// 启动单块在线字幕任务。
  ///
  /// [autoMergeShortSentences] 与设置页的短句合并偏好一致；关闭后仍会还原完整句。
  Future<void> startOnlineTranscription(
    AudioItem audioItem, {
    bool autoMergeShortSentences = true,
  }) async {
    final audioId = audioItem.id;
    // 历史自动检测字幕只读展示，不以任何识别方式重写。
    if (audioItem.transcriptLanguage == 'auto') return;
    final current = state[audioId];
    if (current is OnlineSubtitlePreparing || current is OnlineSubtitleUploading) {
      return;
    }
    _cancelled.remove(audioId);

    final configStore = ref.read(speechConfigStoreProvider);
    final config = await configStore.read();
    final modelId = config?.onlineModelFor(RecognitionPurpose.subtitle) ?? '';
    if (config == null || modelId.isEmpty) {
      _fail(audioId, OnlineSubtitleFailureReason.notConfigured);
      return;
    }
    final apiKey = await configStore.readApiKey();
    if (apiKey == null) {
      _fail(audioId, OnlineSubtitleFailureReason.notConfigured);
      return;
    }
    final credentialVersion = await configStore.readCredentialVersion();
    final identity = SpeechCapability.identityFor(
      kind: config.kind,
      baseUrl: config.baseUrl,
      modelId: modelId,
      credentialVersion: credentialVersion,
    );
    // 准入：只有已验证片段时间戳能力的配置才能生成在线字幕。
    final capability = await ref
        .read(speechCapabilityStoreProvider)
        .read(identity);
    if (capability == null || !capability.segments) {
      _fail(audioId, OnlineSubtitleFailureReason.notVerified);
      return;
    }

    final service = config.kind.name;
    final registry = ref.read(recognitionInFlightTasksProvider);
    final inFlightTask = RecognitionInFlightTask(
      purpose: RecognitionPurpose.subtitle,
      label: audioId,
      onCancel: () async => cancelTranscription(audioId),
    );
    registry.register(inFlightTask);
    final cancelToken = CancelToken();
    _cancelTokens[audioId] = cancelToken;
    File? tempWav;
    try {
      _update(
        audioId,
        OnlineSubtitlePreparing(service: service, modelId: modelId),
      );
      final fileOps = ref.read(transcriptionFileOpsProvider);
      final dataDir = await fileOps.getDataDir();
      final audioPath = audioItem.audioPath;
      if (audioPath == null || audioPath.isEmpty) {
        _fail(audioId, OnlineSubtitleFailureReason.decodeFailed);
        return;
      }
      final fullPath = p.isAbsolute(audioPath)
          ? audioPath
          : p.join(dataDir.path, audioPath);
      final dao = ref.read(audioItemDaoProvider);
      // 识别前记录字幕基线：期间用户导入/编辑过则提交时按冲突保留用户结果。
      final baselineSrt = await dao.getTranscriptSrt(audioId);

      final tmpDir = Directory(p.join(dataDir.path, 'tmp', 'online_subtitle'));
      await tmpDir.create(recursive: true);
      tempWav = File(p.join(tmpDir.path, '${_uuid.v4()}.wav'));
      final decoded = await ref
          .read(localTranscriptionTranscodeServiceProvider)
          .transcodeToPcmWav16k(source: File(fullPath), output: tempWav);
      if (_isCancelled(audioId)) return;
      if (!decoded) {
        _fail(audioId, OnlineSubtitleFailureReason.decodeFailed);
        return;
      }
      final audioBytes = await tempWav.readAsBytes();
      final audioDuration = Duration(
        microseconds:
            audioBytes.length * Duration.microsecondsPerSecond ~/
            _pcmWavBytesPerSecond,
      );
      // 超限直接失败：不截断音频，也不发送注定被拒的请求。
      if (audioDuration > onlineSubtitleMaxDuration ||
          audioBytes.length > onlineSubtitleMaxUploadBytes) {
        _fail(audioId, OnlineSubtitleFailureReason.audioTooLong);
        return;
      }

      _update(audioId, OnlineSubtitleUploading(service: service, modelId: modelId));
      final result = await ref
          .read(speechTranscriptionClientProvider)
          .transcribe(
            config: config,
            apiKey: apiKey,
            modelId: modelId,
            audio: audioBytes,
            fileName: 'subtitle.wav',
            audioDuration: audioDuration,
            format: SpeechResponseFormat.verboseJson,
            requestWordTimestamps: capability.wordTimestamps,
            cancelToken: cancelToken,
          );
      if (_isCancelled(audioId)) return;

      // 每次正式返回都重新校验：纯文本或片段无效的结果不能冒充字幕。
      if (result.text.trim().isEmpty || !result.segmentsValid) {
        _fail(audioId, OnlineSubtitleFailureReason.invalidResult);
        return;
      }
      final srt = await _buildSrt(
        result,
        autoMergeShortSentences: autoMergeShortSentences,
      );
      if (srt == null) {
        _fail(audioId, OnlineSubtitleFailureReason.invalidResult);
        return;
      }
      final sentences = await SubtitleParser.parseSubtitleString(srt);
      final combined = combineModelWordTimestamps(
        sentences: sentences,
        modelWords: capability.wordTimestamps && result.wordsValid
            ? result.words
            : const [],
      );
      final wordsJson = combined.words.isEmpty
          ? null
          : encodeWordTimestamps(combined.words);
      final stats = await getTranscriptStatsFromSrt(srt);
      // 请求期间改了地址、Key 或模型：结果属于旧配置，丢弃且不写库。
      if (_isCancelled(audioId)) return;
      if (await _currentIdentity() != identity) {
        _fail(audioId, OnlineSubtitleFailureReason.configChanged);
        return;
      }

      final commit = await dao.commitTranscription(
        audioItemId: audioId,
        srt: srt,
        wordTimestampsJson: wordsJson,
        transcriptSource: TranscriptSource.online.index,
        transcriptWordTimingSource: combined.source.index,
        transcriptLanguage: 'en',
        sentenceCount: stats.$1,
        wordCount: stats.$2,
        expectedSrt: baselineSrt,
        isCancelled: () => _isCancelled(audioId),
      );
      if (commit == TranscriptCommitResult.conflict) {
        AppLogger.log(
          'OnlineSubtitle',
          '⚠️ 字幕已被用户更新的内容替换，放弃本次结果 id=$audioId',
        );
        _update(audioId, const OnlineSubtitleConflict());
        return;
      }
      if (commit == TranscriptCommitResult.cancelled) {
        AppLogger.log('OnlineSubtitle', '已取消，未写入字幕 id=$audioId');
        return;
      }

      // 事务已提交，才刷新界面内存与完成状态。
      ref
          .read(audioLibraryProvider.notifier)
          .updateAudioItem(
            audioItem.copyWith(
              transcriptPath: null,
              transcriptSource: TranscriptSource.online,
              transcriptWordTimingSource: combined.source,
              transcriptLanguage: 'en',
              sentenceCount: stats.$1,
              wordCount: stats.$2,
            ),
          );
      _update(
        audioId,
        OnlineSubtitleCompleted(
          modelId: modelId,
          wordTimingSource: combined.source,
          reportedCost: result.reportedCost,
        ),
      );
    } catch (error, stackTrace) {
      if (_isCancelled(audioId)) return;
      AppLogger.log('OnlineSubtitle', '❌ 在线字幕失败 id=$audioId | $error');
      if (error is SpeechTranscriptionException &&
          error.kind == SpeechTranscriptionErrorKind.cancelled) {
        return;
      }
      _update(
        audioId,
        OnlineSubtitleFailed(
          OnlineSubtitleFailureReason.unknown,
          speechError: error is SpeechTranscriptionException ? error : null,
        ),
      );
      AppLogger.log('OnlineSubtitle', stackTrace.toString());
    } finally {
      if (tempWav != null) {
        try {
          if (await tempWav.exists()) await tempWav.delete();
        } catch (_) {}
      }
      _cancelled.remove(audioId);
      _cancelTokens.remove(audioId);
      registry.unregister(inFlightTask);
    }
  }

  /// 取消任务：停止等待中的请求，之后不再写库。
  void cancelTranscription(String audioId) {
    if (state[audioId] == null) return;
    _cancelled.add(audioId);
    final token = _cancelTokens[audioId];
    if (token != null && !token.isCancelled) token.cancel();
    _update(audioId, const OnlineSubtitleIdle());
  }

  /// 清除已结束的任务状态。
  void clearState(String audioId) {
    state = Map.of(state)..remove(audioId);
  }

  /// 界面展示用的空闲态（Map 中无条目）。
  static const idle = OnlineSubtitleIdle();

  bool _isCancelled(String audioId) => _cancelled.contains(audioId);

  void _update(String audioId, OnlineSubtitleTaskState taskState) {
    state = Map.of(state)..[audioId] = taskState;
  }

  void _fail(
    String audioId,
    OnlineSubtitleFailureReason reason, {
    SpeechTranscriptionException? speechError,
  }) {
    if (_isCancelled(audioId)) return;
    _update(audioId, OnlineSubtitleFailed(reason, speechError: speechError));
  }

  /// 当前配置与字幕用途的识别身份；与请求开始时不一致即表示配置已变化。
  Future<String?> _currentIdentity() async {
    final configStore = ref.read(speechConfigStoreProvider);
    final config = await configStore.read();
    if (config == null) return null;
    final modelId = config.onlineModelFor(RecognitionPurpose.subtitle);
    if (modelId.isEmpty) return null;
    return SpeechCapability.identityFor(
      kind: config.kind,
      baseUrl: config.baseUrl,
      modelId: modelId,
      credentialVersion: await configStore.readCredentialVersion(),
    );
  }

  /// 片段 → 完整句 →（可选）短句合并 → SRT；无句子时返回 null。
  Future<String?> _buildSrt(
    SpeechTranscriptionResult result, {
    required bool autoMergeShortSentences,
  }) async {
    final segments = [
      for (final segment in result.segments)
        AsrSegment(
          text: segment.text,
          start: Duration(
            microseconds:
                (segment.start * Duration.microsecondsPerSecond).round(),
          ),
          end: Duration(
            microseconds: (segment.end * Duration.microsecondsPerSecond).round(),
          ),
        ),
    ];
    final completeSentences = restoreAsrSentences(segments);
    if (completeSentences.isEmpty) return null;
    final merged = autoMergeShortSentences
        ? mergeShortAsrSegments(completeSentences)
        : completeSentences;
    return generateSrtContent([
      for (final sentence in merged)
        TranscriptSentence(
          text: sentence.text,
          startTime: sentence.start,
          endTime: sentence.end,
        ),
    ]);
  }

  /// 测试入口：直接注入取消标记。
  @visibleForTesting
  void markCancelledForTest(String audioId) => _cancelled.add(audioId);
}

/// 任务空闲（取消或已清除）。
class OnlineSubtitleIdle extends OnlineSubtitleTaskState {
  const OnlineSubtitleIdle();
}
