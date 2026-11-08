/// 练习录音的分块转写：录音超出单块请求范围时按有界分块顺序上传并合并文本。
///
/// 复用长材料字幕已经验证过的分块能力：[planAudioChunks] 规划切点（优先邻近
/// 静音，硬切时相邻块留短重叠），[AudioTranscodeService] 做有界区间提取，
/// [SpeechTranscriptionClient] 只请求文本响应——跟读只需要文本，因此不请求片段
/// 或词时间戳，也不靠均分时长伪造时间信息。
///
/// 服务本身不持有界面状态：[PracticeChunkSession] 由练习会话持有（跟读控制器或
/// 复述在线转写），用录音输入与语音配置身份判断能否续试。失败停在当前块并保留已成功块，下次运行只发送
/// 未完成的块；取消与配置变化都不再开始下一块。临时音频只在会话内使用，丢掉会话
/// 时立即删除，源录音始终不动。
library;

import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:path/path.dart' as p;

import '../../features/audio_import/audio_transcode_service.dart';
import '../../utils/audio_chunk_planner.dart';
import '../app_logger.dart';
import 'speech_config.dart';
import 'speech_transcription_client.dart';

const _logTag = 'PracticeChunk';

/// 分块转写失败的原因；界面据此给出可操作提示。
enum PracticeChunkFailureReason {
  /// 录音或切块无法解码成可上传的 WAV，或切块超出单块范围。
  decodeFailed,

  /// 整段录音都没有可识别的语音。
  noSpeech,

  /// 转写期间语音配置已变化，旧块不能再拼进新配置的结果。
  configChanged,

  /// 用户取消。
  cancelled,

  /// 供应商请求失败；[PracticeChunkFailure.cause] 保留原始分类。
  requestFailed,
}

/// 一次分块转写失败。
///
/// [failedChunk] 是失败块（null 表示还没进入上传）；[mayHaveBeenCharged] 为真表示
/// 失败块的请求已经发出，供应商可能已计费，手动续试会重新上传这一块。
class PracticeChunkFailure implements Exception {
  const PracticeChunkFailure(
    this.reason, {
    this.failedChunk,
    this.cause,
    this.mayHaveBeenCharged = false,
  });

  final PracticeChunkFailureReason reason;
  final AudioChunk? failedChunk;
  final Object? cause;
  final bool mayHaveBeenCharged;

  @override
  String toString() =>
      'PracticeChunkFailure(${reason.name}'
      '${failedChunk == null ? '' : ', chunk=${failedChunk!.index + 1}'})';
}

/// 一次练习录音分块转写的会话进度，由练习会话持有。
///
/// 输入身份是录音路径，配置身份是所用语音服务/模型/凭据版本：任一变化都不能
/// 复用已成功块。已成功块的文本与确认无声的块都记在这里，续试只补未完成部分。
class PracticeChunkSession {
  PracticeChunkSession({
    required this.recordingPath,
    required this.identity,
    required this.duration,
    required this.chunks,
    required this.tempDir,
  });

  /// 被分块的源录音；换录音即换会话。
  final String recordingPath;

  /// 语音配置身份（服务 + 地址 + 模型 + 凭据版本）。
  final String identity;

  /// 整段录音时长。
  final Duration duration;

  final List<AudioChunk> chunks;

  /// 本次会话的临时音频目录，丢掉会话时整目录删除。
  final Directory tempDir;

  final Map<int, String> _texts = {};
  final Set<int> _silent = {};
  double? _reportedCost;

  int get completedCount => _texts.length + _silent.length;

  bool get hasSpeech => _texts.isNotEmpty;

  /// 供应商报告的费用合计；任一块没报告就整段未知（null）。
  double? get reportedCost => _reportedCost;

  bool isHandled(int index) =>
      _texts.containsKey(index) || _silent.contains(index);

  void markSilent(int index) => _silent.add(index);

  /// 收下一块的文本；[reportedCost] 缺失会让整段费用变为未知。
  void collect({
    required AudioChunk chunk,
    required String text,
    double? reportedCost,
  }) {
    _texts[chunk.index] = text.trim();
    _reportedCost = reportedCost == null
        ? null
        : (_reportedCost ?? 0) + reportedCost;
  }

  /// 按块顺序合并文本：只在硬切相邻块之间去掉重叠区里重复识别的词。
  String get text {
    var merged = '';
    for (final chunk in chunks) {
      final part = _texts[chunk.index];
      if (part == null || part.isEmpty) continue;
      if (merged.isEmpty) {
        merged = part;
        continue;
      }
      final previous = chunks[chunk.index - 1];
      merged = previous.hardCut
          ? '$merged ${trimChunkTextOverlap(previousText: merged, nextText: part)}'
          : '$merged $part';
    }
    return merged.trim();
  }

  /// 删除本次会话的全部临时音频；源录音不动。
  Future<void> discardTemp() async {
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (error) {
      AppLogger.log(_logTag, '清理临时音频失败 dir=${tempDir.path} | $error');
    }
  }
}

/// 练习录音的分块转写服务；[client] 与 [transcode] 供测试注入受控边界。
class PracticeChunkTranscriber {
  PracticeChunkTranscriber({required this.client, required this.transcode});

  final SpeechTranscriptionClient client;
  final AudioTranscodeService transcode;

  /// 规划分块会话：测长、按静音优先选切点、建临时目录。
  ///
  /// [audioDuration] 已由录音头解析时直接使用，否则按 16 kHz 提取整段测长；
  /// [isSessionValid] 为假时不再继续规划（取消或换录音）。
  Future<PracticeChunkSession> plan({
    required String recordingPath,
    required String identity,
    Duration? audioDuration,
    bool Function()? isSessionValid,
    void Function(int sessionId)? onSessionStarted,
  }) async {
    final tempDir = await Directory.systemTemp.createTemp('practice_chunk_');
    final source = File(recordingPath);
    try {
      final total =
          audioDuration ??
          await _measure(
            source: source,
            tempDir: tempDir,
            isSessionValid: isSessionValid,
            onSessionStarted: onSessionStarted,
          );
      if (total == null || total <= Duration.zero) {
        throw const PracticeChunkFailure(
          PracticeChunkFailureReason.decodeFailed,
        );
      }
      final chunks = await planAudioChunks(
        totalDuration: total,
        probe: (from, to) async {
          if (isSessionValid != null && !isSessionValid()) return null;
          final probeFile = File(p.join(tempDir.path, 'probe.wav'));
          final extracted = await transcode.transcodeRangeToPcmWav16k(
            source: source,
            output: probeFile,
            start: from,
            duration: to - from,
            onSessionStarted: onSessionStarted,
          );
          if (!extracted) return null;
          final bytes = await probeFile.readAsBytes();
          await _delete(probeFile);
          return quietestCutInPcm(wavBytes: bytes, windowStart: from);
        },
      );
      if (isSessionValid != null && !isSessionValid()) {
        throw const PracticeChunkFailure(PracticeChunkFailureReason.cancelled);
      }
      AppLogger.log(
        _logTag,
        '规划 ${chunks.length} 块 total=${total.inSeconds}s '
        'hardCut=${chunks.where((chunk) => chunk.hardCut).length}',
      );
      return PracticeChunkSession(
        recordingPath: recordingPath,
        identity: identity,
        duration: total,
        chunks: chunks,
        tempDir: tempDir,
      );
    } catch (error) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  /// 顺序转写会话里所有未完成的块。
  ///
  /// 每块都重新确认会话有效与配置身份：[readCurrentIdentity] 与
  /// [PracticeChunkSession.identity] 不一致时抛 [PracticeChunkFailureReason.configChanged]，
  /// 已成功块不会拼进新配置。失败停在当前块，已成功块留在会话里供手动续试。
  Future<void> run({
    required PracticeChunkSession session,
    required SpeechConfig config,
    required String apiKey,
    required String modelId,
    required CancelToken cancelToken,
    bool Function()? isSessionValid,
    Future<String?> Function()? readCurrentIdentity,
    void Function(int sessionId)? onSessionStarted,
    void Function(int completed, int total, int currentChunk)? onProgress,
  }) async {
    final source = File(session.recordingPath);
    for (final chunk in session.chunks) {
      if (session.isHandled(chunk.index)) continue;
      if (_isCancelled(cancelToken, isSessionValid)) {
        throw const PracticeChunkFailure(PracticeChunkFailureReason.cancelled);
      }
      if (readCurrentIdentity != null &&
          await readCurrentIdentity() != session.identity) {
        throw const PracticeChunkFailure(
          PracticeChunkFailureReason.configChanged,
        );
      }
      onProgress?.call(
        session.completedCount,
        session.chunks.length,
        chunk.index + 1,
      );
      final chunkFile = File(
        p.join(session.tempDir.path, 'chunk_${chunk.index}.wav'),
      );
      final extracted = await transcode.transcodeRangeToPcmWav16k(
        source: source,
        output: chunkFile,
        start: chunk.start,
        duration: chunk.duration,
        onSessionStarted: onSessionStarted,
      );
      if (_isCancelled(cancelToken, isSessionValid)) {
        await _delete(chunkFile);
        throw const PracticeChunkFailure(PracticeChunkFailureReason.cancelled);
      }
      final bytes = extracted ? await chunkFile.readAsBytes() : null;
      // 有界区间提取的结果仍要复核上限：超限宁可不发，也不让供应商退回。
      if (bytes == null ||
          bytes.length > audioChunkMaxUploadBytes ||
          chunk.duration > audioChunkMaxDuration) {
        await _delete(chunkFile);
        throw PracticeChunkFailure(
          PracticeChunkFailureReason.decodeFailed,
          failedChunk: chunk,
        );
      }
      if (isSilentPcm(bytes)) {
        // 确认无声的块不上传：既不产生费用，也不让空响应冒充失败。
        AppLogger.log(
          _logTag,
          '跳过确认无声的块 ${chunk.index + 1}/${session.chunks.length}',
        );
        session.markSilent(chunk.index);
        await _delete(chunkFile);
        onProgress?.call(
          session.completedCount,
          session.chunks.length,
          chunk.index + 1,
        );
        continue;
      }
      final SpeechTranscriptionResult result;
      try {
        result = await client.transcribe(
          config: config,
          apiKey: apiKey,
          modelId: modelId,
          audio: bytes,
          fileName: 'shadowing_${chunk.index}.wav',
          audioDuration: chunk.duration,
          // 练习只要求文本：不请求片段时间戳，也不请求词时间戳参数。
          format: SpeechResponseFormat.json,
          cancelToken: cancelToken,
        );
      } on SpeechTranscriptionException catch (error) {
        await _delete(chunkFile);
        if (error.kind == SpeechTranscriptionErrorKind.cancelled) {
          throw const PracticeChunkFailure(
            PracticeChunkFailureReason.cancelled,
          );
        }
        throw PracticeChunkFailure(
          PracticeChunkFailureReason.requestFailed,
          failedChunk: chunk,
          cause: error,
          // 请求已发出，供应商可能已完成识别并计费。
          mayHaveBeenCharged: true,
        );
      }
      await _delete(chunkFile);
      session.collect(
        chunk: chunk,
        text: result.text,
        reportedCost: result.reportedCost,
      );
      onProgress?.call(
        session.completedCount,
        session.chunks.length,
        chunk.index + 1,
      );
    }
    if (!session.hasSpeech) {
      throw const PracticeChunkFailure(PracticeChunkFailureReason.noSpeech);
    }
  }

  /// 整段提取一次只是为了拿时长；提取产物立即删除，源录音不动。
  Future<Duration?> _measure({
    required File source,
    required Directory tempDir,
    bool Function()? isSessionValid,
    void Function(int sessionId)? onSessionStarted,
  }) async {
    final file = File(p.join(tempDir.path, 'measure.wav'));
    final extracted = await transcode.transcodeRangeToPcmWav16k(
      source: source,
      output: file,
      start: Duration.zero,
      onSessionStarted: onSessionStarted,
    );
    if (!extracted) return null;
    final duration = pcmWavDuration(await file.length());
    await _delete(file);
    if (isSessionValid != null && !isSessionValid()) return null;
    return duration;
  }

  bool _isCancelled(CancelToken token, bool Function()? isSessionValid) =>
      token.isCancelled || (isSessionValid != null && !isSessionValid());

  Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      AppLogger.log(_logTag, '删除临时文件失败 path=${file.path} | $error');
    }
  }
}
