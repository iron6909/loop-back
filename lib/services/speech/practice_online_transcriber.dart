/// 练习录音（跟读、复述）的在线转写入口：文件准备、请求边界判定与单块上传。
///
/// 录音停止后先判定格式与大小：单块范围内直接上传原始录音；超出单块范围时
/// 返回 [PracticeRecordingNeedsChunking]，交给练习录音的分块转写按有界分块
/// 顺序上传。本类不截断录音、不改成本机、不自动重试，也不保留半成品。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../asr/audio_file_reader.dart' show readCaf, readWav;
import 'speech_config.dart';
import 'speech_transcription_client.dart';

/// 单块录音的时长上限；超出即改走有界分块，不截断录音。
const practiceOnlineMaxDuration = Duration(minutes: 2);

/// 单块上传的字节上限：既限制内存中的 multipart 体积，也避免触发服务端 413。
const practiceOnlineMaxBytes = 20 * 1024 * 1024;

/// 请求前就能判定的拒绝原因；这些情况不发请求，录音文件原样保留。
enum PracticeRecordingRejection {
  /// 录音文件不存在或为空。
  fileMissing,

  /// 不是跟读后端产出的 WAV / CAF。
  unsupportedFormat,

  /// 文件可读但没有可上传的音频样本。
  emptyAudio,
}

/// 录音不满足单块请求条件；[rejection] 供界面给出可操作原因。
class PracticeRecordingRejected implements Exception {
  const PracticeRecordingRejected(this.rejection);

  final PracticeRecordingRejection rejection;

  @override
  String toString() => 'PracticeRecordingRejected(${rejection.name})';
}

/// 请求前的录音判定结果：单块内直接上传，或超出单块范围需要分块。
sealed class PracticeRecordingAccess {
  const PracticeRecordingAccess();
}

/// 超出单块请求范围：由练习录音的分块转写顺序上传，不截断也不只传开头。
class PracticeRecordingNeedsChunking extends PracticeRecordingAccess {
  const PracticeRecordingNeedsChunking({this.duration});

  /// 已从音频头解析出的真实时长；文件大到无法整份读入时为 null，由分块转写测长。
  final Duration? duration;
}

/// 通过格式与边界检查、可直接上传的录音。
class PracticeRecordingUpload extends PracticeRecordingAccess {
  const PracticeRecordingUpload({
    required this.bytes,
    required this.fileName,
    required this.contentType,
    required this.duration,
  });

  final Uint8List bytes;
  final String fileName;

  /// multipart 文件的媒体类型，由文件头而不是扩展名决定。
  final String contentType;

  /// 由音频头解析出的真实时长，用于校验供应商返回的时间戳范围。
  final Duration duration;
}

/// 练习录音在线的准入结果：要么可以发请求，要么给出拒绝原因。
sealed class PracticeOnlineAccess {
  const PracticeOnlineAccess();
}

/// 已具备 Key、上传告知与该用途（跟读或复述）自己的文本能力验证。
class PracticeOnlineAccessGranted extends PracticeOnlineAccess {
  const PracticeOnlineAccessGranted({
    required this.config,
    required this.apiKey,
    required this.modelId,
    required this.identity,
  });

  final SpeechConfig config;
  final String apiKey;

  /// 该用途自己的在线模型，不借用字幕或其它用途的选择。
  final String modelId;

  /// 非秘密配置身份：分块进度只在同一身份下可以续试。
  final String identity;
}

/// 拒绝发请求的原因；界面据此引导用户补配置或补验证。
enum PracticeOnlineAccessDenial {
  /// 没有保存服务地址或 Key。
  missingConfiguration,

  /// 首次向该服务上传录音前还没有完成告知。
  uploadNoticeMissing,

  /// 该用途的模型没有通过有效文本能力验证（或配置已变化使验证失效）。
  capabilityUnverified,
}

/// 不具备在线转写条件；此时不得上传任何音频。
class PracticeOnlineAccessDenied extends PracticeOnlineAccess
    implements Exception {
  const PracticeOnlineAccessDenied(this.reason);

  final PracticeOnlineAccessDenial reason;

  @override
  String toString() => 'PracticeOnlineAccessDenied(${reason.name})';
}

/// 练习录音在线转写的阶段，界面用它显示进度。
enum PracticeOnlinePhase { preparing, uploading, completed, failed }

/// 一次在线转写的界面状态：服务、模型、进度与费用。
class PracticeOnlineState {
  const PracticeOnlineState({
    required this.serviceHost,
    required this.modelId,
    required this.phase,
    this.progress,
    this.reportedCost,
    this.error,
    this.completedChunks = 0,
    this.totalChunks = 0,
    this.retryable = false,
    this.mayHaveBeenCharged = false,
  });

  /// 接收音频的服务主机名，不含协议与路径。
  final String serviceHost;

  final String modelId;
  final PracticeOnlinePhase phase;

  /// 上传进度 0~1；供应商未提供总量时为 null。
  final double? progress;

  /// 供应商报告的本次费用；null 表示未知，界面不能显示为免费。
  final double? reportedCost;

  /// 失败原因（[SpeechTranscriptionException] / [PracticeRecordingRejected] /
  /// [PracticeOnlineAccessDenied] / [PracticeChunkFailure]），交给
  /// [speechErrorText] 显示。
  final Object? error;

  /// 分块进度：已成功或确认无声的块数；未分块时为 0。
  final int completedChunks;

  /// 本次录音规划出的块数；未分块时为 0。
  final int totalChunks;

  /// 失败后是否保留未完成块，可由用户手动续试。
  final bool retryable;

  /// 失败块可能已被供应商计费；续试会重新上传这一块。
  final bool mayHaveBeenCharged;

  bool get isCompleted => phase == PracticeOnlinePhase.completed;
  bool get isFailed => phase == PracticeOnlinePhase.failed;

  /// 是否按多块顺序上传。
  bool get isChunked => totalChunks > 1;

  PracticeOnlineState copyWith({
    PracticeOnlinePhase? phase,
    double? progress,
    double? reportedCost,
    Object? error,
    int? completedChunks,
    int? totalChunks,
    bool? retryable,
    bool? mayHaveBeenCharged,
  }) => PracticeOnlineState(
    serviceHost: serviceHost,
    modelId: modelId,
    phase: phase ?? this.phase,
    progress: progress ?? this.progress,
    reportedCost: reportedCost ?? this.reportedCost,
    error: error ?? this.error,
    completedChunks: completedChunks ?? this.completedChunks,
    totalChunks: totalChunks ?? this.totalChunks,
    retryable: retryable ?? this.retryable,
    mayHaveBeenCharged: mayHaveBeenCharged ?? this.mayHaveBeenCharged,
  );
}

/// 练习录音的在线转写：单块直接上传，超出单块范围交由分块编排。
///
/// [client] 复用 #7 落地的 [SpeechTranscriptionClient]，测试注入假 transport；
/// 本类不另建 HTTP 客户端，也不重试或换供应商。
class PracticeOnlineTranscriber {
  PracticeOnlineTranscriber({SpeechTranscriptionClient? client})
    : _client = client ?? SpeechTranscriptionClient();

  final SpeechTranscriptionClient _client;

  /// 判定录音怎么上传：单块内直接返回可上传字节，超出单块范围返回需要分块。
  ///
  /// 格式不可识别或没有音频样本时抛 [PracticeRecordingRejected]；这些情况不发
  /// 请求，源录音原样保留。
  Future<PracticeRecordingAccess> prepare(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw const PracticeRecordingRejected(
        PracticeRecordingRejection.fileMissing,
      );
    }
    final byteLength = await file.length();
    if (byteLength == 0) {
      throw const PracticeRecordingRejected(
        PracticeRecordingRejection.fileMissing,
      );
    }
    // 超出单块字节上限时不必整份读入：先按文件头确认格式，再交给分块转写测长。
    if (byteLength > practiceOnlineMaxBytes) {
      _formatOf(await file.openRead(0, 12).first);
      return const PracticeRecordingNeedsChunking();
    }
    final bytes = await file.readAsBytes();
    final format = _formatOf(bytes);
    final duration = _durationOf(bytes, format);
    if (duration <= Duration.zero) {
      throw const PracticeRecordingRejected(
        PracticeRecordingRejection.emptyAudio,
      );
    }
    if (duration > practiceOnlineMaxDuration) {
      return PracticeRecordingNeedsChunking(duration: duration);
    }
    return PracticeRecordingUpload(
      bytes: bytes,
      fileName: _fileNameOf(filePath, format),
      contentType: format.contentType,
      duration: duration,
    );
  }

  /// 只发一次文本转写请求；失败原样抛出，由调用方显示原因并等用户决定。
  Future<SpeechTranscriptionResult> transcribe({
    required SpeechConfig config,
    required String apiKey,
    required String modelId,
    required PracticeRecordingUpload recording,
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) => _client.transcribe(
    config: config,
    apiKey: apiKey,
    modelId: modelId,
    audio: recording.bytes,
    fileName: recording.fileName,
    audioDuration: recording.duration,
    // 练习录音只需要文本：不请求片段时间戳，也不请求词时间戳参数。
    format: SpeechResponseFormat.json,
    fileContentType: recording.contentType,
    onSendProgress: onProgress == null
        ? null
        : (sent, total) {
            if (total <= 0) return;
            onProgress((sent / total).clamp(0.0, 1.0));
          },
    cancelToken: cancelToken,
  );

  /// 由文件头判断录音格式；跟读后端只产出 WAV 与 CAF。
  _RecordingFormat _formatOf(List<int> bytes) {
    if (bytes.length < 12) {
      throw const PracticeRecordingRejected(
        PracticeRecordingRejection.emptyAudio,
      );
    }
    final magic = String.fromCharCodes(bytes.sublist(0, 4));
    return switch (magic) {
      'RIFF' => _RecordingFormat.wav,
      'caff' => _RecordingFormat.caf,
      _ => throw const PracticeRecordingRejected(
        PracticeRecordingRejection.unsupportedFormat,
      ),
    };
  }

  /// 用现有音频头解析取真实时长；无法解析按空音频处理，不猜时长。
  Duration _durationOf(Uint8List bytes, _RecordingFormat format) {
    final data = ByteData.sublistView(bytes);
    final audio = switch (format) {
      _RecordingFormat.wav => readWav(data),
      _RecordingFormat.caf => readCaf(data),
    };
    if (audio.sampleRate <= 0 || audio.samples.isEmpty) return Duration.zero;
    return Duration(
      microseconds:
          (audio.samples.length * Duration.microsecondsPerSecond) ~/
          audio.sampleRate,
    );
  }

  /// 上传文件名沿用录音文件名（含正确扩展名），便于供应商识别格式。
  String _fileNameOf(String filePath, _RecordingFormat format) {
    final name = filePath.split(RegExp(r'[/\\]')).last;
    if (name.contains('.')) return name;
    return '$name.${format.extension}';
  }
}

/// 跟读后端可能产出的两种容器。
enum _RecordingFormat {
  wav('audio/wav', 'wav'),
  caf('audio/x-caf', 'caf');

  const _RecordingFormat(this.contentType, this.extension);

  final String contentType;
  final String extension;
}
