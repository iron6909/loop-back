/// 长材料在线字幕任务：按有界块顺序上传，失败后只续试未完成块。
///
/// 流水线：按材料时长规划分块（切点优先邻近静音）→ 复用既有音频转换边界逐块提取
/// 16 kHz WAV → 确认无声的块跳过上传 → 一次文件转写请求（`verbose_json` 片段时间戳，
/// 已确认支持的配置才请求词时间戳）→ 完整句还原、边界局部对齐 → 全部块成功后
/// 合并、校验并经既有安全提交边界整体写入字幕与元数据。
///
/// 任务由全局 provider 在进程内持有检查点：已成功块的结果、输入身份与配置身份都
/// 留在内存里，关闭/重开弹窗或切换页面不清除可续试的失败任务；用户重试只发送
/// 失败与未完成块。输入、配置或后处理偏好不同的块不混用。主动取消、删除材料或
/// 接受相关配置变更后停止后续请求并清理临时结果。整份无语音如实报告，不覆盖字幕。
///
/// 首期没有可靠系统后台执行或进程重启恢复：进程结束后检查点与临时音频一并丢弃，
/// 下次启动只清理遗留临时文件，不尝试恢复旧任务。
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
import '../models/word_timestamp.dart';
import '../services/app_logger.dart';
import '../services/asr/offline_asr_engine.dart' show AsrSegment;
import '../services/speech/speech_capability.dart';
import '../services/speech/speech_transcription_client.dart';
import '../services/subtitle_parser.dart';
import '../utils/audio_chunk_planner.dart';
import '../utils/model_word_timestamps.dart';
import '../utils/srt_generator.dart';
import '../utils/transcript_stats.dart';
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

/// 在线字幕失败的本地原因；供应商失败另由 [OnlineSubtitleFailed.speechError] 表达。
enum OnlineSubtitleFailureReason {
  /// 尚未保存在线语音服务地址或 Key。
  notConfigured,

  /// 当前配置没有通过字幕（片段时间戳）能力验证。
  notVerified,

  /// 音频无法解码为可上传的 WAV，或提取出的切片超出单块范围。
  decodeFailed,

  /// 供应商对有内容的块返回空结果，或文本、片段通不过校验。
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

/// 进行中：顺序处理各块，[completedChunks] 为已成功或确认无声的块数。
class OnlineSubtitleWorking extends OnlineSubtitleTaskState {
  const OnlineSubtitleWorking({
    required this.service,
    required this.modelId,
    this.completedChunks = 0,
    this.totalChunks = 0,
    this.currentChunk,
  });

  /// 当前服务（预设名称或自定义），用于界面提示。
  final String service;

  /// 本次使用的在线模型 ID。
  final String modelId;

  final int completedChunks;
  final int totalChunks;

  /// 正在处理的块序号（1 起）；还在准备时为 null。
  final int? currentChunk;
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

  /// 供应商报告的费用合计；null 表示未知，不能显示成免费。
  final double? reportedCost;
}

/// 整份材料确认无语音：不写入字幕，保留用户已有内容。
class OnlineSubtitleNoSpeech extends OnlineSubtitleTaskState {
  const OnlineSubtitleNoSpeech();
}

/// 本次失败，未写入任何字幕。[speechError] 非空时为供应商错误分类。
///
/// [retryable] 为真表示检查点仍在：重试只重发失败与未完成块，已完成块不再上传。
/// [mayHaveBeenCharged] 为真表示失败块的请求已经发出，供应商可能已计费。
class OnlineSubtitleFailed extends OnlineSubtitleTaskState {
  const OnlineSubtitleFailed(
    this.reason, {
    this.speechError,
    this.completedChunks = 0,
    this.totalChunks = 0,
    this.failedChunk,
    this.mayHaveBeenCharged = false,
    this.retryable = false,
  });

  final OnlineSubtitleFailureReason reason;
  final SpeechTranscriptionException? speechError;
  final int completedChunks;
  final int totalChunks;

  /// 失败块序号（1 起）；未开始处理任何块时为 null。
  final int? failedChunk;
  final bool mayHaveBeenCharged;
  final bool retryable;
}

/// 提交时发现目标字幕已被用户导入或编辑替换：保留用户较新的结果。
class OnlineSubtitleConflict extends OnlineSubtitleTaskState {
  const OnlineSubtitleConflict();
}

/// 任务空闲（取消或已清除）。
class OnlineSubtitleIdle extends OnlineSubtitleTaskState {
  const OnlineSubtitleIdle();
}

/// 在线字幕任务管理器。
///
/// 全局 provider 持有任务与进程内检查点：弹窗关闭后请求继续，重新打开仍能看到
/// 进度、失败位置与可续试状态。同一材料同时只允许一个在途任务，重复启动被忽略。
final onlineSubtitleTaskManagerProvider =
    NotifierProvider<OnlineSubtitleTaskManager, Map<String, OnlineSubtitleTaskState>>(
      OnlineSubtitleTaskManager.new,
    );

/// 维护在线字幕任务状态与进程内检查点，并保证只有全部块成功才写库。
class OnlineSubtitleTaskManager
    extends Notifier<Map<String, OnlineSubtitleTaskState>> {
  final Set<String> _cancelled = {};
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, int> _transcodeSessions = {};

  /// 进程内检查点：材料 id → 本次任务的成功块、身份与临时目录。
  final Map<String, _OnlineSubtitleRun> _runs = {};
  final _uuid = const Uuid();

  @override
  Map<String, OnlineSubtitleTaskState> build() => {};

  /// 获取指定材料的在线任务状态。
  OnlineSubtitleTaskState? taskState(String audioId) => state[audioId];

  /// 启动或续试在线字幕任务。
  ///
  /// [autoMergeShortSentences] 与设置页的短句合并偏好一致；关闭后仍会还原完整句。
  /// 输入、配置与该偏好都与检查点一致时从第一个未完成块继续，否则重新开始。
  Future<void> startOnlineTranscription(
    AudioItem audioItem, {
    bool autoMergeShortSentences = true,
  }) async {
    final audioId = audioItem.id;
    // 历史自动检测字幕只读展示，不以任何识别方式重写。
    if (audioItem.transcriptLanguage == 'auto') return;
    final current = state[audioId];
    if (current is OnlineSubtitleWorking) return;
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
    final identity = SpeechCapability.identityFor(
      kind: config.kind,
      baseUrl: config.baseUrl,
      modelId: modelId,
      credentialVersion: await configStore.readCredentialVersion(),
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
      usesOnlineSpeech: true,
      onCancel: () async => cancelTranscription(audioId),
    );
    registry.register(inFlightTask);
    final cancelToken = CancelToken();
    _cancelTokens[audioId] = cancelToken;
    File? chunkFile;
    try {
      _update(audioId, OnlineSubtitleWorking(service: service, modelId: modelId));

      final fileOps = ref.read(transcriptionFileOpsProvider);
      final dataDir = await fileOps.getDataDir();
      final audioPath = audioItem.audioPath;
      if (audioPath == null || audioPath.isEmpty) {
        _fail(audioId, OnlineSubtitleFailureReason.decodeFailed);
        return;
      }
      final sourceFile = File(
        p.isAbsolute(audioPath) ? audioPath : p.join(dataDir.path, audioPath),
      );
      final dao = ref.read(audioItemDaoProvider);

      // 检查点只在输入、配置与后处理偏好都一致时复用；否则整份重来，绝不混用。
      final inputId = _inputIdentity(audioItem, audioPath);
      final checkpoint = _runs[audioId];
      if (checkpoint != null &&
          (checkpoint.inputId != inputId ||
              checkpoint.identity != identity ||
              checkpoint.mergeShortSentences != autoMergeShortSentences)) {
        await _discardRun(audioId);
      }
      var run = _runs[audioId];
      if (run == null) {
        run = await _planRun(
          audioId: audioId,
          audioItem: audioItem,
          sourceFile: sourceFile,
          dataDir: dataDir,
          inputId: inputId,
          identity: identity,
          modelId: modelId,
          wordTimestamps: capability.wordTimestamps,
          mergeShortSentences: autoMergeShortSentences,
        );
        if (run == null) return;
        _runs[audioId] = run;
      }
      final runIdentity = run.identity;
      final transcode = ref.read(localTranscriptionTranscodeServiceProvider);
      final client = ref.read(speechTranscriptionClientProvider);

      for (final chunk in run.chunks) {
        if (run.isHandled(chunk.index)) continue;
        if (_isCancelled(audioId)) return;
        // 配置变化后不再发送新块：已完成块属于旧配置，不能与新结果混用。
        if (await _currentIdentity() != runIdentity) {
          _fail(audioId, OnlineSubtitleFailureReason.configChanged, run: run);
          return;
        }
        // 材料已被删除：停止后续请求并清理临时结果，不写库。
        if (await dao.getById(audioId) == null) {
          AppLogger.log('OnlineSubtitle', '材料已删除，停止后续请求 id=$audioId');
          await _discardRun(audioId);
          clearState(audioId);
          _cancelled.add(audioId);
          return;
        }

        _update(
          audioId,
          OnlineSubtitleWorking(
            service: service,
            modelId: modelId,
            completedChunks: run.completedCount,
            totalChunks: run.chunks.length,
            currentChunk: chunk.index + 1,
          ),
        );
        chunkFile = File(p.join(run.tempDir.path, 'chunk_${chunk.index}.wav'));
        final extracted = await transcode.transcodeRangeToPcmWav16k(
          source: sourceFile,
          output: chunkFile,
          start: chunk.start,
          duration: chunk.duration,
          onSessionStarted: (sessionId) =>
              _transcodeSessions[audioId] = sessionId,
        );
        _transcodeSessions.remove(audioId);
        if (_isCancelled(audioId)) return;
        final bytes = extracted ? await chunkFile.readAsBytes() : null;
        // 有界区间提取的结果仍要复核上限：超限宁可不发，也不让供应商退回。
        if (bytes == null ||
            bytes.length > audioChunkMaxUploadBytes ||
            chunk.duration > audioChunkMaxDuration) {
          _fail(
            audioId,
            OnlineSubtitleFailureReason.decodeFailed,
            run: run,
            failedChunk: chunk,
          );
          return;
        }
        if (isSilentPcm(bytes)) {
          // 确认无声的块不上传：既省请求，也不让供应商返回空结果冒充失败。
          AppLogger.log(
            'OnlineSubtitle',
            '跳过确认无声的块 id=$audioId chunk=${chunk.index + 1}/${run.chunks.length}',
          );
          run.markSilent(chunk.index);
          await _deleteFile(chunkFile);
          chunkFile = null;
          _reportProgress(audioId, service, modelId, run);
          continue;
        }

        final SpeechTranscriptionResult result;
        try {
          result = await client.transcribe(
            config: config,
            apiKey: apiKey,
            modelId: modelId,
            audio: bytes,
            fileName: 'subtitle_${chunk.index}.wav',
            audioDuration: chunk.duration,
            format: SpeechResponseFormat.verboseJson,
            requestWordTimestamps: run.wordTimestamps,
            cancelToken: cancelToken,
          );
        } on SpeechTranscriptionException catch (error) {
          if (_isCancelled(audioId) ||
              error.kind == SpeechTranscriptionErrorKind.cancelled) {
            return;
          }
          AppLogger.log(
            'OnlineSubtitle',
            '❌ 第 ${chunk.index + 1}/${run.chunks.length} 块失败 id=$audioId | $error',
          );
          _fail(
            audioId,
            OnlineSubtitleFailureReason.unknown,
            speechError: error,
            run: run,
            failedChunk: chunk,
            mayHaveBeenCharged: true,
          );
          return;
        }
        if (_isCancelled(audioId)) return;
        // 有声或无法确认无声的块返回空结果/无效片段一律失败：不能把可能的语音
        // 内容当成静音跳过，也不能用无效时间戳拼字幕。
        if (result.text.trim().isEmpty || !result.segmentsValid) {
          _fail(
            audioId,
            OnlineSubtitleFailureReason.invalidResult,
            run: run,
            failedChunk: chunk,
            mayHaveBeenCharged: true,
          );
          return;
        }

        run.collect(chunk: chunk, result: result);
        await _deleteFile(chunkFile);
        chunkFile = null;
        _reportProgress(audioId, service, modelId, run);
      }

      // 整份无语音：如实报告，不覆盖用户已有字幕。
      if (!run.hasSpeech) {
        AppLogger.log('OnlineSubtitle', '整份材料无可识别语音 id=$audioId');
        _update(audioId, const OnlineSubtitleNoSpeech());
        await _discardRun(audioId);
        return;
      }
      await _commit(audioId: audioId, audioItem: audioItem, run: run, dao: dao);
    } catch (error, stackTrace) {
      if (_isCancelled(audioId)) return;
      AppLogger.log('OnlineSubtitle', '❌ 在线字幕失败 id=$audioId | $error');
      AppLogger.log('OnlineSubtitle', stackTrace.toString());
      _fail(
        audioId,
        OnlineSubtitleFailureReason.unknown,
        speechError: error is SpeechTranscriptionException ? error : null,
        run: _runs[audioId],
      );
    } finally {
      if (chunkFile != null) await _deleteFile(chunkFile);
      _transcodeSessions.remove(audioId);
      // 取消后不留检查点与临时音频；失败时保留，供用户只续试未完成块。
      if (_isCancelled(audioId)) await _discardRun(audioId);
      _cancelled.remove(audioId);
      _cancelTokens.remove(audioId);
      registry.unregister(inFlightTask);
    }
  }

  /// 取消任务：停止等待中的请求与提取，清理临时结果，之后不再写库。
  void cancelTranscription(String audioId) {
    if (state[audioId] == null) return;
    _cancelled.add(audioId);
    final token = _cancelTokens[audioId];
    if (token != null && !token.isCancelled) token.cancel();
    final sessionId = _transcodeSessions.remove(audioId);
    if (sessionId != null) {
      ref.read(localTranscriptionTranscodeServiceProvider).cancelSession(sessionId);
    }
    _update(audioId, const OnlineSubtitleIdle());
  }

  /// 清除已结束的任务状态，不动仍未完成的检查点。
  void clearState(String audioId) {
    state = Map.of(state)..remove(audioId);
  }

  /// 界面展示用的空闲态（Map 中无条目）。
  static const idle = OnlineSubtitleIdle();

  bool _isCancelled(String audioId) => _cancelled.contains(audioId);

  void _update(String audioId, OnlineSubtitleTaskState taskState) {
    state = Map.of(state)..[audioId] = taskState;
  }

  /// 记录失败；[run] 非空表示已有成功块可以续试。
  void _fail(
    String audioId,
    OnlineSubtitleFailureReason reason, {
    SpeechTranscriptionException? speechError,
    _OnlineSubtitleRun? run,
    AudioChunk? failedChunk,
    bool mayHaveBeenCharged = false,
  }) {
    if (_isCancelled(audioId)) return;
    // 配置变化、未配置或未验证时，检查点里的块已经属于无效配置，不给续试入口。
    final retryable =
        run != null &&
        reason != OnlineSubtitleFailureReason.notConfigured &&
        reason != OnlineSubtitleFailureReason.notVerified &&
        reason != OnlineSubtitleFailureReason.configChanged;
    _update(
      audioId,
      OnlineSubtitleFailed(
        reason,
        speechError: speechError,
        completedChunks: run?.completedCount ?? 0,
        totalChunks: run?.chunks.length ?? 0,
        failedChunk: failedChunk == null ? null : failedChunk.index + 1,
        mayHaveBeenCharged: mayHaveBeenCharged,
        retryable: retryable,
      ),
    );
  }

  /// 块进度更新：块数与失败位置都要让界面看到，不假装有精确百分比。
  void _reportProgress(
    String audioId,
    String service,
    String modelId,
    _OnlineSubtitleRun run,
  ) {
    if (_isCancelled(audioId)) return;
    _update(
      audioId,
      OnlineSubtitleWorking(
        service: service,
        modelId: modelId,
        completedChunks: run.completedCount,
        totalChunks: run.chunks.length,
      ),
    );
  }

  /// 建一个可续试的检查点：分块方案、输入/配置身份与临时目录。
  Future<_OnlineSubtitleRun?> _planRun({
    required String audioId,
    required AudioItem audioItem,
    required File sourceFile,
    required Directory dataDir,
    required String inputId,
    required String identity,
    required String modelId,
    required bool wordTimestamps,
    required bool mergeShortSentences,
  }) async {
    final transcode = ref.read(localTranscriptionTranscodeServiceProvider);
    final total = audioItem.totalDuration > 0
        ? Duration(seconds: audioItem.totalDuration)
        : await _measureDuration(sourceFile, dataDir);
    if (total == null) {
      _fail(audioId, OnlineSubtitleFailureReason.decodeFailed);
      return null;
    }
    final tmpDir = Directory(
      p.join(dataDir.path, 'tmp', 'online_subtitle', _uuid.v4()),
    );
    await tmpDir.create(recursive: true);

    // 切点探测：只提取目标切点附近的一小段，用真实音量找静音，失败就硬切。
    final chunks = await planAudioChunks(
      totalDuration: total,
      probe: (from, to) async {
        if (_isCancelled(audioId)) return null;
        final probeFile = File(p.join(tmpDir.path, 'probe.wav'));
        final extracted = await transcode.transcodeRangeToPcmWav16k(
          source: sourceFile,
          output: probeFile,
          start: from,
          duration: to - from,
          onSessionStarted: (sessionId) =>
              _transcodeSessions[audioId] = sessionId,
        );
        _transcodeSessions.remove(audioId);
        if (!extracted) return null;
        final bytes = await probeFile.readAsBytes();
        await _deleteFile(probeFile);
        return quietestCutInPcm(wavBytes: bytes, windowStart: from);
      },
    );
    if (_isCancelled(audioId)) {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
      return null;
    }
    AppLogger.log(
      'OnlineSubtitle',
      '规划 ${chunks.length} 块 id=$audioId total=${total.inSeconds}s '
          'hardCut=${chunks.where((c) => c.hardCut).length}',
    );
    final baselineSrt = await ref.read(audioItemDaoProvider).getTranscriptSrt(
      audioId,
    );
    return _OnlineSubtitleRun(
      inputId: inputId,
      identity: identity,
      modelId: modelId,
      wordTimestamps: wordTimestamps,
      mergeShortSentences: mergeShortSentences,
      baselineSrt: baselineSrt,
      chunks: chunks,
      tempDir: tmpDir,
    );
  }

  /// 材料缺时长时整段解码一次测长；之后按块重新提取，源媒体不动。
  ///
  /// shortcut: 未知时长会多占一次整段临时 WAV 的磁盘，时长已知时不做这步。
  Future<Duration?> _measureDuration(File sourceFile, Directory dataDir) async {
    final tmpDir = Directory(p.join(dataDir.path, 'tmp', 'online_subtitle'));
    await tmpDir.create(recursive: true);
    final file = File(p.join(tmpDir.path, '${_uuid.v4()}_probe.wav'));
    final extracted = await ref
        .read(localTranscriptionTranscodeServiceProvider)
        .transcodeToPcmWav16k(source: sourceFile, output: file);
    final duration = extracted
        ? pcmWavDuration(await file.length())
        : null;
    await _deleteFile(file);
    if (duration == null || duration <= Duration.zero) return null;
    return duration;
  }

  /// 全部块成功后合并、校验并原子提交；提交前仍要复查配置身份与取消。
  Future<void> _commit({
    required String audioId,
    required AudioItem audioItem,
    required _OnlineSubtitleRun run,
    required AudioItemDao dao,
  }) async {
    final ordered = <AsrSegment>[
      for (final chunk in run.chunks) ...?run.segments[chunk.index],
    ];
    final sentences = run.mergeShortSentences
        ? mergeShortAsrSegments(ordered)
        : ordered;
    if (sentences.isEmpty) {
      _fail(audioId, OnlineSubtitleFailureReason.invalidResult, run: run);
      return;
    }
    final srt = generateSrtContent([
      for (final sentence in sentences)
        TranscriptSentence(
          text: sentence.text,
          startTime: sentence.start,
          endTime: sentence.end,
        ),
    ]);
    final parsed = await SubtitleParser.parseSubtitleString(srt);
    final combined = combineModelWordTimestamps(
      sentences: parsed,
      modelWords: [
        for (final chunk in run.chunks) ...?run.words[chunk.index],
      ],
    );
    final wordsJson = combined.words.isEmpty
        ? null
        : encodeWordTimestamps(combined.words);
    final stats = await getTranscriptStatsFromSrt(srt);
    if (_isCancelled(audioId)) return;
    if (await _currentIdentity() != run.identity) {
      _fail(audioId, OnlineSubtitleFailureReason.configChanged, run: run);
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
      expectedSrt: run.baselineSrt,
      isCancelled: () => _isCancelled(audioId),
    );
    if (commit == TranscriptCommitResult.conflict) {
      AppLogger.log(
        'OnlineSubtitle',
        '⚠️ 字幕已被用户更新的内容替换，放弃本次结果 id=$audioId',
      );
      _update(audioId, const OnlineSubtitleConflict());
      await _discardRun(audioId);
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
    AppLogger.log(
      'OnlineSubtitle',
      '在线字幕已提交 id=$audioId chunks=${run.chunks.length} '
          'segments=${parsed.length} wordTiming=${combined.source.name}',
    );
    _update(
      audioId,
      OnlineSubtitleCompleted(
        modelId: run.modelId,
        wordTimingSource: combined.source,
        reportedCost: run.reportedCost,
      ),
    );
    await _discardRun(audioId);
  }

  /// 清掉某材料的进程内检查点与临时音频。
  Future<void> _discardRun(String audioId) async {
    final run = _runs.remove(audioId);
    if (run == null) return;
    try {
      if (await run.tempDir.exists()) await run.tempDir.delete(recursive: true);
    } catch (error) {
      AppLogger.log('OnlineSubtitle', '清理临时音频失败 dir=${run.tempDir.path} | $error');
    }
  }

  Future<void> _deleteFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      AppLogger.log('OnlineSubtitle', '删除临时文件失败 path=${file.path} | $error');
    }
  }

  /// 当前配置与字幕用途的识别身份；与任务开始时不一致即表示配置已变化。
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

  /// 输入身份：路径与时长。换材料（或重新导入不同内容）不能续用旧块。
  String _inputIdentity(AudioItem audioItem, String audioPath) =>
      '$audioPath|${audioItem.totalDuration}';

  /// 测试入口：检查点数量，用于确认取消、提交后已清理。
  @visibleForTesting
  int get checkpointCountForTest => _runs.length;
}

/// 一次在线字幕任务的进程内检查点。
///
/// 只保存在内存里：关闭页面或弹窗不影响它，进程结束即失效。已成功块按绝对时间
/// 保存句子与模型词，续试时不再重新上传这些块。
class _OnlineSubtitleRun {
  _OnlineSubtitleRun({
    required this.inputId,
    required this.identity,
    required this.modelId,
    required this.wordTimestamps,
    required this.mergeShortSentences,
    required this.baselineSrt,
    required this.chunks,
    required this.tempDir,
  });

  /// 输入身份与配置身份：二者任一变化都不能复用已成功块。
  final String inputId;
  final String identity;
  final String modelId;
  final bool wordTimestamps;
  final bool mergeShortSentences;

  /// 识别前的字幕基线：提交时对比，期间用户导入/编辑过则按冲突保留用户结果。
  final String? baselineSrt;
  final List<AudioChunk> chunks;
  final Directory tempDir;

  /// 已成功块的完整句（绝对时间）。
  final Map<int, List<AsrSegment>> segments = {};

  /// 已成功块的模型词时间戳（绝对时间），只有该块确实给出合法词时才有。
  final Map<int, List<SpeechTranscriptWord>> words = {};

  /// 确认无声而跳过的块。
  final Set<int> silent = {};

  double? _cost;

  int get completedCount => segments.length + silent.length;

  bool get hasSpeech => segments.isNotEmpty;

  /// 供应商报告的费用合计；任一块没报告就整份未知。
  double? get reportedCost => _cost;

  bool isHandled(int index) =>
      segments.containsKey(index) || silent.contains(index);

  void markSilent(int index) => silent.add(index);

  /// 收下一块的识别结果：换算成绝对时间，并只去掉重叠区里重复识别的边界文本。
  void collect({
    required AudioChunk chunk,
    required SpeechTranscriptionResult result,
  }) {
    final offset = chunk.start;
    final restored = restoreAsrSentences([
      for (final segment in result.segments)
        AsrSegment(
          text: segment.text,
          start: offset + _seconds(segment.start),
          end: offset + _seconds(segment.end),
        ),
    ]);
    final previousChunk = chunk.index == 0 ? null : chunks[chunk.index - 1];
    final previousSegments = chunk.index == 0
        ? const <AsrSegment>[]
        : segments[chunk.index - 1] ?? const <AsrSegment>[];
    // 只有硬切才共享音频：重叠区内两边的结果要用局部对齐去重。
    segments[chunk.index] =
        previousChunk == null || !previousChunk.hardCut
        ? restored
        : trimChunkOverlap(
            previousTail: [
              for (final segment in previousSegments)
                if (segment.end > previousChunk.end - audioChunkOverlap)
                  segment,
            ],
            next: restored,
            boundary: previousChunk.end,
          );
    if (result.wordsValid) {
      words[chunk.index] = [
        for (final word in result.words)
          SpeechTranscriptWord(
            word: word.word,
            start: word.start + _secondsOf(offset),
            end: word.end + _secondsOf(offset),
          ),
      ];
    }
    final cost = result.reportedCost;
    _cost = cost == null ? null : (_cost ?? 0) + cost;
  }
}

/// 秒 → 时长；供应商按秒返回，统一进 Duration 后再做偏移。
Duration _seconds(double seconds) =>
    Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());

/// 时长 → 秒，供模型词时间戳的绝对偏移使用。
double _secondsOf(Duration duration) =>
    duration.inMicroseconds / Duration.microsecondsPerSecond;
