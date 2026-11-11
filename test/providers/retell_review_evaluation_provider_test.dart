/// 复述入口：无登录、按复述自己的识别身份复用转写、识别失败短路及 attempt 竞态。
///
/// 在线分支的可控边界只有网络客户端：录音文件是真实临时 WAV，准入、单块边界、
/// 身份比对与状态流转都走真实代码，测试不发付费请求、不读取真实 Key。
library;
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:loop_back/features/audio_import/audio_transcode_service.dart';
import 'package:loop_back/models/recognition_selection.dart';
import 'package:loop_back/models/retell_review_evaluation.dart';
import 'package:loop_back/providers/local_transcription_task_provider.dart';
import 'package:loop_back/providers/recognition_settings_provider.dart';
import 'package:loop_back/providers/retell_review_evaluation_provider.dart';
import 'package:loop_back/providers/speech_capability_provider.dart';
import 'package:loop_back/providers/speech_configuration_provider.dart';
import 'package:loop_back/services/sentence_ai_api_client.dart';
import 'package:loop_back/services/speech/practice_chunk_transcriber.dart';
import 'package:loop_back/services/speech/practice_online_transcriber.dart';
import 'package:loop_back/services/speech/speech_capability.dart';
import 'package:loop_back/services/speech/speech_config.dart';
import 'package:loop_back/services/speech/speech_config_store.dart';
import 'package:loop_back/services/speech/speech_transcription_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Api extends Mock implements SentenceAiApiClient {}

const _baseUrl = 'https://openrouter.ai/api/v1';
const _retellOnlineModel = 'openai/whisper-retell';
const _apiKey = 'shadow1';
const _onlineText = 'My online retelling';

/// 记录请求参数并返回预设结果的语音客户端替身。
///
/// 只替换网络边界：请求次数、实际模型、输出格式与上传时长都可断言，用来验证
/// 真实模型选择、「语音、文字两类请求各发一次」的隔离，以及分块的顺序与续试。
class _SpeechClient extends SpeechTranscriptionClient {
  _SpeechClient({this.error, this.gated = false, this.gatedCalls = const {}});

  /// 非空时每次请求都失败，用来验证识别失败不进入评估。
  final Object? error;

  /// 供应商报告的费用；null 表示供应商没给，界面必须显示为未知。
  double? reportedCost = 0.0002;

  /// 为真时首块请求挂起，直到 [release] 放行，用来观察取消与旧结果。
  final bool gated;

  /// 只挂起这些调用序号（从 0 开始），用来观察分块中途的取消与配置变化。
  final Set<int> gatedCalls;

  /// 返回的文本；真实客户端对空文本会直接报错，这里模拟通道给了空串。
  String text = _onlineText;

  /// 按调用序号返回文本或失败；为空时用 [text] / [error]。
  Future<SpeechTranscriptionResult> Function(int index)? onCall;

  final List<String> models = [];
  final List<String> apiKeys = [];
  final List<Duration> durations = [];
  final List<SpeechResponseFormat> formats = [];
  final List<bool> wordRequests = [];
  final Completer<void> _started = Completer<void>();
  final List<Completer<void>> _gates = [];

  int get calls => models.length;

  /// 请求已进入客户端（此时 [release] 一定有效），用来观察在途状态。
  Future<void> get started => _started.future;

  void release() {
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  @override
  Future<SpeechTranscriptionResult> transcribe({
    required SpeechConfig config,
    required String apiKey,
    required String modelId,
    required Uint8List audio,
    required String fileName,
    required Duration audioDuration,
    SpeechResponseFormat format = SpeechResponseFormat.verboseJson,
    bool requestWordTimestamps = false,
    String fileContentType = 'audio/wav',
    void Function(int sent, int total)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    final index = calls;
    models.add(modelId);
    apiKeys.add(apiKey);
    durations.add(audioDuration);
    formats.add(format);
    wordRequests.add(requestWordTimestamps);
    if (gated || gatedCalls.contains(index)) {
      final gate = Completer<void>();
      _gates.add(gate);
      if (!_started.isCompleted) _started.complete();
      await gate.future;
    }
    if (!_started.isCompleted) _started.complete();
    final handler = onCall;
    if (handler != null) return handler(index);
    final failure = error;
    if (failure != null) throw failure;
    return SpeechTranscriptionResult(
      text: text,
      reportedCost: reportedCost,
    );
  }
}

/// 内置一份齐备在线语音配置的存储替身（Key 与凭据版本也在内存中）。
class _InMemorySpeechConfigStore extends SpeechConfigStore {
  SpeechConfig? config = const SpeechConfig(
    kind: SpeechProviderKind.openrouter,
    baseUrl: _baseUrl,
    onlineModels: {
      RecognitionPurpose.retell: _retellOnlineModel,
      RecognitionPurpose.subtitle: 'openai/whisper-subtitle',
      RecognitionPurpose.shadowing: 'openai/whisper-shadowing',
    },
  );
  String? apiKey = _apiKey;

  @override
  Future<SpeechConfig?> read() async => config;

  @override
  Future<String?> readApiKey() async => apiKey;

  @override
  Future<String?> readCredentialVersion() async => 'credential-a';
}

/// 能力结论与上传告知的内存替身，只覆盖复述用途。
class _InMemoryCapabilityStore extends SpeechCapabilityStore {
  _InMemoryCapabilityStore({this.textVerified = true, this.noticeDone = true});

  final bool textVerified;
  final bool noticeDone;

  SpeechCapability _capability() => SpeechCapability(
    identity: SpeechCapability.identityFor(
      kind: SpeechProviderKind.openrouter,
      baseUrl: _baseUrl,
      modelId: _retellOnlineModel,
      credentialVersion: 'credential-a',
    ),
    text: textVerified,
    segments: false,
    wordTimestamps: false,
    validatedAt: DateTime(2026, 11, 8),
  );

  @override
  Future<Map<String, SpeechCapability>> readAll() async =>
      textVerified ? {_capability().identity: _capability()} : const {};

  @override
  Future<SpeechCapability?> read(String identity) async {
    final capability = _capability();
    return textVerified && capability.identity == identity ? capability : null;
  }

  @override
  Future<bool> hasUploadNotice(String baseUrl) async => noticeDone;
}

/// 生成指定时长、16 kHz 单声道 PCM16 WAV，用来覆盖单块边界。
Uint8List _wavBytes(Duration duration) {
  const sampleRate = 16000;
  final dataSize = sampleRate * duration.inMilliseconds ~/ 1000 * 2;
  final bytes = ByteData(44 + dataSize);
  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataSize, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, dataSize, Endian.little);
  return bytes.buffer.asUint8List();
}

/// 固定复述选择，避免测试依赖偏好读写。
class _FixedRecognitionSettings extends RecognitionSettingsNotifier {
  _FixedRecognitionSettings(this._fixed);

  final RecognitionSettings _fixed;

  @override
  RecognitionSettings build() => _fixed;
}

/// 生成指定时长、16 kHz 单声道 PCM16 的字节，供分块探测与上传。
///
/// [silent] 为真时写成确认无声的块，用来验证不浪费请求。
Uint8List _pcmBytes(Duration duration, {bool silent = false}) {
  final samples = duration.inMicroseconds * 16000 ~/ 1000000;
  final bytes = Uint8List(samples * 2);
  for (var i = 0; i < samples; i++) {
    if (silent) continue;
    final value = i.isEven ? 8000 : -8000;
    bytes[i * 2] = value & 0xff;
    bytes[i * 2 + 1] = (value >> 8) & 0xff;
  }
  return bytes;
}

/// 假转码：按请求区间写出对应时长的 PCM，并记录每次提取范围。
///
/// 分块规划与合并走真实代码，只把不可控的 ffmpeg 边界换成受控写入。
class _FakeTranscode extends AudioTranscodeService {
  _FakeTranscode({this.silence = false});

  /// 为真时所有提取结果都是确认无声，用来验证整份无语音。
  final bool silence;

  final List<({Duration start, Duration? duration})> ranges = [];

  @override
  Future<bool> transcodeRangeToPcmWav16k({
    required File source,
    required File output,
    required Duration start,
    Duration? duration,
    void Function(int sessionId)? onSessionStarted,
  }) async {
    ranges.add((start: start, duration: duration));
    onSessionStarted?.call(ranges.length);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(
      _pcmBytes(duration ?? const Duration(seconds: 1), silent: silence),
    );
    return true;
  }

  @override
  void cancelSession(int sessionId) {}
}

const _retellModelId = 'retell-model';

RecognitionSettings _retellLocal() => const RecognitionSettings(
  subtitle: RecognitionSelection.local('subtitle-model'),
  shadowing: RecognitionSelection.local('shadowing-model'),
  retell: RecognitionSelection.local(_retellModelId),
);

RecognitionSettings _retellSystem() => const RecognitionSettings(
  subtitle: RecognitionSelection.local('subtitle-model'),
  shadowing: RecognitionSelection.local('shadowing-model'),
  retell: RecognitionSelection.system(),
);

RecognitionSettings _retellOnline() => const RecognitionSettings(
  subtitle: RecognitionSelection.local('subtitle-model'),
  shadowing: RecognitionSelection.local('shadowing-model'),
  retell: RecognitionSelection.online(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Api api;
  late ProviderContainer container;
  var transcriptions = 0;
  String? transcript;

  ProviderContainer buildContainer({required RecognitionSettings settings}) =>
      ProviderContainer(overrides: [
        sentenceAiApiClientProvider.overrideWithValue(api),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(settings),
        ),
        retellTranscriptProvider.overrideWithValue((_) async {
          transcriptions++; return transcript;
        }),
      ]);

  setUp(() {
    api = _Api(); transcriptions = 0; transcript = 'My retelling';
    when(() => api.evaluateTranscriptStream(
      transcript: any(named: 'transcript'), originalText: any(named: 'originalText'),
      targetLanguage: any(named: 'targetLanguage'), cancelToken: any(named: 'cancelToken'),
    )).thenAnswer((_) => Stream.value(const RetellReviewStreamFrame(
      evaluation: RetellReviewEvaluation(summary: '反馈'), isFinal: true)));
    container = buildContainer(settings: _retellLocal());
  });
  tearDown(() => container.dispose());

  Future<void> evaluate({String key = 'attempt', String? reused,
    String? reusedIdentity}) => container
    .read(retellReviewEvaluationProvider.notifier).evaluate(attemptKey: key,
      recordingPath: '/recording.wav', originalText: 'Original',
      targetLanguage: 'zh-CN', localTranscript: reused,
      localTranscriptIdentity: reusedIdentity);

  test('无需登录，本机转写后评估，重复打开复用当前 attempt', () async {
    await evaluate(); await evaluate();
    expect(container.read(retellReviewEvaluationProvider).phase,
      RetellReviewEvaluationPhase.completed);
    expect(transcriptions, 1);
    verify(() => api.evaluateTranscriptStream(transcript: 'My retelling',
      originalText: 'Original', targetLanguage: 'zh-CN',
      cancelToken: any(named: 'cancelToken'))).called(1);
  });
  test('同 attempt 且实际识别身份匹配的转写直接复用', () async {
    await evaluate(reused: 'Already recognized',
      reusedIdentity: 'local:$_retellModelId');
    expect(transcriptions, 0);
    expect(container.read(retellReviewEvaluationProvider).phase,
      RetellReviewEvaluationPhase.completed);
  });
  test('识别身份不匹配时不复用，按复述自己的选择重新转写', () async {
    await evaluate(reused: 'Borrowed from subtitle',
      reusedIdentity: 'local:subtitle-model');
    expect(transcriptions, 1);
    verify(() => api.evaluateTranscriptStream(transcript: 'My retelling',
      originalText: 'Original', targetLanguage: 'zh-CN',
      cancelToken: any(named: 'cancelToken'))).called(1);
  });
  test('没有识别身份的旧转写不能当作同源结果复用', () async {
    await evaluate(reused: 'Unknown source');
    expect(transcriptions, 1);
  });
  test('转写失败不调用供应商', () async {
    transcript = null;
    await evaluate();
    expect(container.read(retellReviewEvaluationProvider).errorCode,
      'transcription_failed');
    verifyNever(() => api.evaluateTranscriptStream(
      transcript: any(named: 'transcript'), originalText: any(named: 'originalText'),
      targetLanguage: any(named: 'targetLanguage'), cancelToken: any(named: 'cancelToken')));
  });
  test('系统识别方式无法对录音文件转写时明确失败，不自动改用其它方式', () async {
    container.dispose();
    container = buildContainer(settings: _retellSystem());
    await evaluate(reused: 'Other source', reusedIdentity: 'local:subtitle-model');
    expect(transcriptions, 0, reason: '系统方式不能对录音文件做二次转写');
    expect(container.read(retellReviewEvaluationProvider).errorCode,
      'transcription_failed');
    verifyNever(() => api.evaluateTranscriptStream(
      transcript: any(named: 'transcript'), originalText: any(named: 'originalText'),
      targetLanguage: any(named: 'targetLanguage'), cancelToken: any(named: 'cancelToken')));
  });
  test('切换 attempt 后旧转写不能写回或发请求', () async {
    final gate = Completer<String?>();
    container.dispose();
    container = ProviderContainer(overrides: [
      sentenceAiApiClientProvider.overrideWithValue(api),
      recognitionSettingsProvider.overrideWith(
        () => _FixedRecognitionSettings(_retellLocal()),
      ),
      retellTranscriptProvider.overrideWithValue((_) => gate.future),
    ]);
    final pending = evaluate();
    container.read(retellReviewEvaluationProvider.notifier).syncAttempt('next');
    gate.complete('Old transcript'); await pending;
    expect(container.read(retellReviewEvaluationProvider).attemptKey, 'next');
    expect(container.read(retellReviewEvaluationProvider).evaluation, isNull);
    verifyNever(() => api.evaluateTranscriptStream(
      transcript: any(named: 'transcript'), originalText: any(named: 'originalText'),
      targetLanguage: any(named: 'targetLanguage'), cancelToken: any(named: 'cancelToken')));
  });

  group('在线转写与文字评估分离', () {
    late Directory tempDir;
    late String recordingPath;
    late _SpeechClient speech;
    late _InMemorySpeechConfigStore configStore;

    /// 组装一个在线复述环境：默认条件齐备，按需关掉某一项模拟准入失败。
    ProviderContainer buildOnline({
      _SpeechClient? client,
      AudioTranscodeService? transcode,
      String? onlineModel = _retellOnlineModel,
      bool textVerified = true,
      bool noticeDone = true,
    }) {
      speech = client ?? _SpeechClient();
      configStore = _InMemorySpeechConfigStore();
      if (onlineModel == null) {
        configStore.config = const SpeechConfig(
          kind: SpeechProviderKind.openrouter,
          baseUrl: _baseUrl,
        );
      }
      return ProviderContainer(overrides: [
        sentenceAiApiClientProvider.overrideWithValue(api),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_retellOnline()),
        ),
        speechConfigStoreProvider.overrideWithValue(configStore),
        speechCapabilityStoreProvider.overrideWithValue(
          _InMemoryCapabilityStore(
            textVerified: textVerified,
            noticeDone: noticeDone,
          ),
        ),
        speechTranscriptionClientProvider.overrideWithValue(speech),
        // 分块要切真实录音，只替换不可控的转码边界。
        localTranscriptionTranscodeServiceProvider.overrideWithValue(
          transcode ?? _FakeTranscode(),
        ),
        retellTranscriptProvider.overrideWithValue(
          (_) async => throw StateError('在线方式不得借用本机转写'),
        ),
      ]);
    }

    /// 重新指向在线环境的容器：每个用例自带一份，避免状态串场。
    ProviderContainer switchToOnline({
      _SpeechClient? client,
      AudioTranscodeService? transcode,
      String? onlineModel = _retellOnlineModel,
      bool textVerified = true,
      bool noticeDone = true,
    }) {
      container.dispose();
      container = buildOnline(
        client: client,
        transcode: transcode,
        onlineModel: onlineModel,
        textVerified: textVerified,
        noticeDone: noticeDone,
      );
      return container;
    }

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('retell_online_eval');
      final file = File('${tempDir.path}/recording.wav');
      await file.writeAsBytes(_wavBytes(const Duration(seconds: 3)));
      recordingPath = file.path;
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    /// 在线方式的实际识别身份：服务类型、根地址与复述自己的在线模型。
    String identityOf({String model = _retellOnlineModel}) =>
        onlineRecognitionIdentity(
          const SpeechConfig(
            kind: SpeechProviderKind.openrouter,
            baseUrl: _baseUrl,
          ),
          model,
        );

    Future<void> evaluateOnline({
      String key = 'attempt',
      String? reused,
      String? reusedIdentity,
      String? path,
    }) => container
        .read(retellReviewEvaluationProvider.notifier)
        .evaluate(
          attemptKey: key,
          recordingPath: path ?? recordingPath,
          originalText: 'Original',
          targetLanguage: 'zh-CN',
          localTranscript: reused,
          localTranscriptIdentity: reusedIdentity,
        );

    test('用复述自己的在线模型转写一次，评估只请求文字服务一次', () async {
      switchToOnline();
      await evaluateOnline();

      expect(speech.calls, 1, reason: '转写只上传一次');
      expect(
        speech.models,
        [_retellOnlineModel],
        reason: '实际模型来自复述用途，不借用字幕或跟读的在线模型',
      );
      expect(speech.apiKeys, [_apiKey]);
      verify(
        () => api.evaluateTranscriptStream(
          transcript: _onlineText,
          originalText: 'Original',
          targetLanguage: 'zh-CN',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      final state = container.read(retellReviewEvaluationProvider);
      expect(state.phase, RetellReviewEvaluationPhase.completed);
      expect(state.onlineSpeech?.reportedCost, 0.0002);
    });

    test('供应商没有报告费用时保持未知，不按免费处理', () async {
      switchToOnline(client: _SpeechClient()..reportedCost = null);
      await evaluateOnline();

      final state = container.read(retellReviewEvaluationProvider);
      expect(state.phase, RetellReviewEvaluationPhase.completed);
      expect(state.onlineSpeech, isNotNull, reason: '本次评估确实经过在线语音');
      expect(state.onlineSpeech?.reportedCost, isNull);
    });

    test('同一次尝试且在线身份匹配时复用转写，不再上传', () async {
      switchToOnline();
      await evaluateOnline(reused: 'Already recognized', reusedIdentity: identityOf());

      expect(speech.calls, 0, reason: '同一段在线转写不重复计费');
      verify(
        () => api.evaluateTranscriptStream(
          transcript: 'Already recognized',
          originalText: 'Original',
          targetLanguage: 'zh-CN',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      expect(
        container.read(retellReviewEvaluationProvider).onlineSpeech,
        isNotNull,
        reason: '复用的是在线结果，费用未知也要如实标记',
      );
    });

    test('换了在线模型后不复用旧文本，按本次操作重新识别', () async {
      switchToOnline();
      await evaluateOnline(
        reused: 'From another model',
        reusedIdentity: identityOf(model: 'openai/previous-retell'),
      );

      expect(speech.calls, 1, reason: '身份不匹配时必须按当前配置识别');
      expect(speech.models, [_retellOnlineModel]);
      verify(
        () => api.evaluateTranscriptStream(
          transcript: _onlineText,
          originalText: 'Original',
          targetLanguage: 'zh-CN',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    test('在线转写失败时不调用文字服务，错误归为语音错误', () async {
      switchToOnline(
        client: _SpeechClient(
          error: const SpeechTranscriptionException(
            SpeechTranscriptionErrorKind.unauthorized,
            statusCode: 401,
          ),
        ),
      );
      await evaluateOnline();

      final state = container.read(retellReviewEvaluationProvider);
      expect(state.phase, RetellReviewEvaluationPhase.failed);
      expect(
        state.speechError,
        isA<SpeechTranscriptionException>().having(
          (error) => error.kind,
          'kind',
          SpeechTranscriptionErrorKind.unauthorized,
        ),
        reason: '语音失败要能按鉴权错误呈现',
      );
      expect(state.errorCode, isNull, reason: '语音错误不是文字 AI 错误');
      verifyNever(
        () => api.evaluateTranscriptStream(
          transcript: any(named: 'transcript'),
          originalText: any(named: 'originalText'),
          targetLanguage: any(named: 'targetLanguage'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });

    test('在线返回空文本时按语音错误呈现，不评估', () async {
      switchToOnline(client: _SpeechClient()..text = '   ');
      await evaluateOnline();

      final state = container.read(retellReviewEvaluationProvider);
      expect(state.phase, RetellReviewEvaluationPhase.failed);
      expect(
        state.speechError,
        isA<SpeechTranscriptionException>().having(
          (error) => error.kind,
          'kind',
          SpeechTranscriptionErrorKind.emptyResult,
        ),
        reason: '在线没给文本属于语音侧失败，不能显示成本机模型问题',
      );
      verifyNever(
        () => api.evaluateTranscriptStream(
          transcript: any(named: 'transcript'),
          originalText: any(named: 'originalText'),
          targetLanguage: any(named: 'targetLanguage'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });

    test('在线准入未就绪时不上传也不评估', () async {
      switchToOnline(textVerified: false);
      await evaluateOnline();

      expect(speech.calls, 0);
      expect(
        container.read(retellReviewEvaluationProvider).speechError,
        isA<PracticeOnlineAccessDenied>(),
      );
      verifyNever(
        () => api.evaluateTranscriptStream(
          transcript: any(named: 'transcript'),
          originalText: any(named: 'originalText'),
          targetLanguage: any(named: 'targetLanguage'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });

    test('切换 attempt 后旧在线结果不覆盖新尝试，也不评估', () async {
      final gated = _SpeechClient(gated: true);
      switchToOnline(client: gated);

      final pending = evaluateOnline();
      // 请求已发出并挂起，此时用户切到另一段录音。
      await gated.started;
      container.read(retellReviewEvaluationProvider.notifier).syncAttempt('next');
      gated.release();
      await pending;

      final state = container.read(retellReviewEvaluationProvider);
      expect(state.attemptKey, 'next');
      expect(state.evaluation, isNull);
      verifyNever(
        () => api.evaluateTranscriptStream(
          transcript: any(named: 'transcript'),
          originalText: any(named: 'originalText'),
          targetLanguage: any(named: 'targetLanguage'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });

    /// 写出一段超过单块范围的真实录音，返回它的路径。
    Future<String> writeLongRecording(String name) async {
      final file = File('${tempDir.path}/$name');
      await file.writeAsBytes(_wavBytes(const Duration(minutes: 5)));
      return file.path;
    }

    test('超出单块范围时顺序分块，评估只用合并后的完整文本', () async {
      final client = _SpeechClient()
        ..onCall = (index) async => SpeechTranscriptionResult(
          text: ['first part', 'second part', 'third part'][index],
          reportedCost: 0.0002,
        );
      switchToOnline(client: client);
      final longPath = await writeLongRecording('long.wav');

      await evaluateOnline(path: longPath);

      expect(client.calls, 3, reason: '五分钟录音按有界分块顺序上传三块');
      expect(
        client.models,
        everyElement(_retellOnlineModel),
        reason: '分块继续用复述自己的在线模型',
      );
      expect(
        client.formats,
        everyElement(SpeechResponseFormat.json),
        reason: '纯文本用途不请求片段时间戳',
      );
      expect(
        client.wordRequests,
        everyElement(isFalse),
        reason: '纯文本用途不请求词时间戳',
      );
      final uploaded = client.durations.fold(
        Duration.zero,
        (sum, each) => sum + each,
      );
      expect(
        uploaded,
        greaterThanOrEqualTo(const Duration(minutes: 5)),
        reason: '整段录音都进了转写，不截取开头也不均分时长伪造',
      );
      verify(
        () => api.evaluateTranscriptStream(
          transcript: 'first part second part third part',
          originalText: 'Original',
          targetLanguage: 'zh-CN',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      final state = container.read(retellReviewEvaluationProvider);
      expect(state.phase, RetellReviewEvaluationPhase.completed);
      expect(
        state.onlineSpeech?.reportedCost,
        closeTo(0.0006, 1e-9),
        reason: '费用按块累加',
      );
    });

    test('真实重复的话语跨块保留，不去重成一句', () async {
      final client = _SpeechClient()
        ..onCall = (index) async => SpeechTranscriptionResult(
          text: index == 0 ? 'I asked him twice' : 'He said no. He said no.',
        );
      switchToOnline(client: client);

      await evaluateOnline(path: await writeLongRecording('repeat.wav'));

      verify(
        () => api.evaluateTranscriptStream(
          transcript: 'I asked him twice He said no. He said no.',
          originalText: 'Original',
          targetLanguage: 'zh-CN',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    test('分块失败停在失败块，评估不调用；手动续试只重发未完成部分', () async {
      final client = _SpeechClient();
      final texts = ['first part', 'second part', 'third part'];
      client.onCall = (index) async {
        if (index == 1) {
          throw const SpeechTranscriptionException(
            SpeechTranscriptionErrorKind.timeout,
          );
        }
        // 首次只有第 0 块成功；续试从第 2 次调用起依次发出未完成的块。
        return SpeechTranscriptionResult(
          text: index == 0 ? texts[0] : texts[index - 1],
          reportedCost: 0.0002,
        );
      };
      switchToOnline(client: client);
      final longPath = await writeLongRecording('retry.wav');

      await evaluateOnline(path: longPath);

      final state = container.read(retellReviewEvaluationProvider);
      expect(state.phase, RetellReviewEvaluationPhase.failed);
      expect(
        state.speechError,
        isA<PracticeChunkFailure>()
            .having(
              (error) => error.reason,
              'reason',
              PracticeChunkFailureReason.requestFailed,
            )
            .having((error) => error.failedChunk?.index, 'failedChunk', 1)
            .having(
              (error) => error.mayHaveBeenCharged,
              'mayHaveBeenCharged',
              isTrue,
            ),
        reason: '超时块可能已计费，续试要让用户知道会再发一次',
      );
      expect(client.calls, 2, reason: '失败后不再请求后续块');
      verifyNever(
        () => api.evaluateTranscriptStream(
          transcript: any(named: 'transcript'),
          originalText: any(named: 'originalText'),
          targetLanguage: any(named: 'targetLanguage'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );

      // 用户手动续试：只补失败块与后面未完成的块，已成功块不再上传。
      await evaluateOnline(path: longPath);

      expect(client.calls, 4, reason: '续试只重发未成功的两块');
      verify(
        () => api.evaluateTranscriptStream(
          transcript: 'first part second part third part',
          originalText: 'Original',
          targetLanguage: 'zh-CN',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
      expect(
        container.read(retellReviewEvaluationProvider).phase,
        RetellReviewEvaluationPhase.completed,
      );
    });

    test('换了录音不复用旧块，从第一块重新转写', () async {
      final client = _SpeechClient();
      client.onCall = (index) async {
        if (index == 1) {
          throw const SpeechTranscriptionException(
            SpeechTranscriptionErrorKind.serverError,
          );
        }
        return SpeechTranscriptionResult(text: 'part ${index + 1}');
      };
      switchToOnline(client: client);
      final firstPath = await writeLongRecording('first.wav');
      final secondPath = await writeLongRecording('second.wav');

      await evaluateOnline(path: firstPath);
      expect(client.calls, 2, reason: '第一段在第二块失败');

      await evaluateOnline(key: 'second', path: secondPath);

      expect(client.calls, 5, reason: '新录音重新规划三块，不接着旧进度');
      verify(
        () => api.evaluateTranscriptStream(
          transcript: 'part 3 part 4 part 5',
          originalText: 'Original',
          targetLanguage: 'zh-CN',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    test('取消后不再发后续块，临时分块不留给下一次转写', () async {
      final client = _SpeechClient(gatedCalls: {0})
        ..onCall = (index) async =>
            SpeechTranscriptionResult(text: 'part ${index + 1}');
      switchToOnline(client: client);
      final longPath = await writeLongRecording('cancel.wav');

      final pending = evaluateOnline(path: longPath);
      // 第一块已发出并挂起，此时用户切到另一段。
      await client.started;
      container.read(retellReviewEvaluationProvider.notifier).syncAttempt('next');
      client.release();
      await pending;

      expect(client.calls, 1, reason: '取消后不再开始下一块');
      expect(container.read(retellReviewEvaluationProvider).attemptKey, 'next');
      verifyNever(
        () => api.evaluateTranscriptStream(
          transcript: any(named: 'transcript'),
          originalText: any(named: 'originalText'),
          targetLanguage: any(named: 'targetLanguage'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );

      // 回到同一段录音：取消时已丢掉临时结果，从第一块重新转写。
      await evaluateOnline(key: 'attempt', path: longPath);
      expect(client.calls, 4, reason: '重新规划三块，不接着已取消的进度');
      verify(
        () => api.evaluateTranscriptStream(
          transcript: 'part 2 part 3 part 4',
          originalText: 'Original',
          targetLanguage: 'zh-CN',
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    });

    test('分块期间复述在线身份变化时停发后续块，不评估', () async {
      final client = _SpeechClient(gatedCalls: {0})
        ..onCall = (index) async =>
            SpeechTranscriptionResult(text: 'part ${index + 1}');
      switchToOnline(client: client);
      final longPath = await writeLongRecording('identity.wav');

      final pending = evaluateOnline(path: longPath);
      await client.started;
      // 用户在分块转写未完成时换掉复述的在线模型：旧块不属于新配置。
      configStore.config = const SpeechConfig(
        kind: SpeechProviderKind.openrouter,
        baseUrl: _baseUrl,
        onlineModels: {RecognitionPurpose.retell: 'openai/whisper-next'},
      );
      client.release();
      await pending;

      final state = container.read(retellReviewEvaluationProvider);
      expect(state.phase, RetellReviewEvaluationPhase.failed);
      expect(
        state.speechError,
        isA<PracticeChunkFailure>().having(
          (error) => error.reason,
          'reason',
          PracticeChunkFailureReason.configChanged,
        ),
      );
      expect(client.calls, 1, reason: '配置变了就不再上传后续块');
      verifyNever(
        () => api.evaluateTranscriptStream(
          transcript: any(named: 'transcript'),
          originalText: any(named: 'originalText'),
          targetLanguage: any(named: 'targetLanguage'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });

    test('整份录音都没有语音时不上传，按没有可识别语音失败', () async {
      final client = _SpeechClient();
      switchToOnline(client: client, transcode: _FakeTranscode(silence: true));

      await evaluateOnline(path: await writeLongRecording('silent.wav'));

      final state = container.read(retellReviewEvaluationProvider);
      expect(state.phase, RetellReviewEvaluationPhase.failed);
      expect(
        state.speechError,
        isA<PracticeChunkFailure>().having(
          (error) => error.reason,
          'reason',
          PracticeChunkFailureReason.noSpeech,
        ),
      );
      expect(client.calls, 0, reason: '确认无声的块不上传也不计费');
      verifyNever(
        () => api.evaluateTranscriptStream(
          transcript: any(named: 'transcript'),
          originalText: any(named: 'originalText'),
          targetLanguage: any(named: 'targetLanguage'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });

    test('转写期间复述在线模型被改时丢弃本次文本，不评估', () async {
      final gated = _SpeechClient(gated: true);
      switchToOnline(client: gated);

      final pending = evaluateOnline();
      await gated.started;
      // 用户在转写未完成时换掉复述的在线模型：旧文本不再代表当前选择。
      configStore.config = const SpeechConfig(
        kind: SpeechProviderKind.openrouter,
        baseUrl: _baseUrl,
        onlineModels: {RecognitionPurpose.retell: 'openai/whisper-next'},
      );
      gated.release();
      await pending;

      final state = container.read(retellReviewEvaluationProvider);
      expect(state.phase, RetellReviewEvaluationPhase.idle);
      expect(state.evaluation, isNull);
      verifyNever(
        () => api.evaluateTranscriptStream(
          transcript: any(named: 'transcript'),
          originalText: any(named: 'originalText'),
          targetLanguage: any(named: 'targetLanguage'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });
  });
}
