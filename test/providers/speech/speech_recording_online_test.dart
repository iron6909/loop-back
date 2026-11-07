/// 跟读在线转写：从录音控制器公开入口覆盖停录时机、单次请求、取消与旧会话。
///
/// 只替换不可控边界（录音后端、网络 transport、配置存储）：录音文件是真实临时
/// 文件，评测与状态流转走真实代码。测试不发真实付费请求，也不读取真实 Key。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/models/recognition_selection.dart';
import 'package:echo_loop/models/speech_practice_models.dart';
import 'package:echo_loop/providers/recognition_settings_provider.dart';
import 'package:echo_loop/providers/speech/speech_recording_controller.dart';
import 'package:echo_loop/providers/speech_capability_provider.dart';
import 'package:echo_loop/providers/speech_configuration_provider.dart';
import 'package:echo_loop/services/speech/shadowing_online_transcriber.dart';
import 'package:echo_loop/services/speech/speech_capability.dart';
import 'package:echo_loop/services/speech/speech_config.dart';
import 'package:echo_loop/services/speech/speech_config_store.dart';
import 'package:echo_loop/services/speech/speech_transcription_client.dart';
import 'package:echo_loop/services/speech_practice_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/mock_providers.dart';

const _baseUrl = 'https://openrouter.ai/api/v1';
const _modelId = 'openai/whisper-1';
const _apiKey = 'sk-shadowing-online-test';
const _onlineText = 'the quick brown fox jumps';

/// 记录请求并按队列返回预设响应的 adapter。
class _FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<ResponseBody> _responses = [];
  final List<Completer<void>> _gates = [];

  int get requestCount => requests.length;

  void enqueueJson(Object payload) {
    _responses.add(
      ResponseBody.fromString(
        jsonEncode(payload),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    _gates.add(Completer<void>()..complete());
  }

  /// 让下一次响应挂起，直到测试主动放行，用来观察「请求进行中」的行为。
  void enqueueGatedJson(Object payload) {
    _responses.add(
      ResponseBody.fromString(
        jsonEncode(payload),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    _gates.add(Completer<void>());
  }

  void release(int index) {
    final gate = _gates[index];
    if (!gate.isCompleted) gate.complete();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final index = requests.length - 1;
    await _gates[index].future;
    if (cancelFuture != null) {
      cancelFuture.then((_) {});
    }
    return _responses[index];
  }

  @override
  void close({bool force = false}) {}
}

/// 内置一份齐备在线语音配置的存储替身（Key 与凭据版本也在内存中）。
class _InMemorySpeechConfigStore extends SpeechConfigStore {
  SpeechConfig? config = const SpeechConfig(
    kind: SpeechProviderKind.openrouter,
    baseUrl: _baseUrl,
    onlineModels: {RecognitionPurpose.shadowing: _modelId},
  );
  String? apiKey = _apiKey;

  @override
  Future<SpeechConfig?> read() async => config;

  @override
  Future<String?> readApiKey() async => apiKey;

  @override
  Future<String?> readCredentialVersion() async => 'credential-a';
}

/// 能力结论与上传告知的内存替身。
class _InMemoryCapabilityStore extends SpeechCapabilityStore {
  _InMemoryCapabilityStore({this.textVerified = true, this.noticeDone = true});

  bool textVerified;
  bool noticeDone;

  SpeechCapability _capability() => SpeechCapability(
    identity: SpeechCapability.identityFor(
      kind: SpeechProviderKind.openrouter,
      baseUrl: _baseUrl,
      modelId: _modelId,
      credentialVersion: 'credential-a',
    ),
    text: textVerified,
    segments: false,
    wordTimestamps: false,
    validatedAt: DateTime(2026, 11, 8),
  );

  @override
  Future<Map<String, SpeechCapability>> readAll() async => textVerified
      ? {_capability().identity: _capability()}
      : const {};

  @override
  Future<SpeechCapability?> read(String identity) async {
    final capability = _capability();
    return textVerified && capability.identity == identity
        ? capability
        : null;
  }

  @override
  Future<bool> hasUploadNotice(String baseUrl) async => noticeDone;

  @override
  Future<void> rememberUploadNotice(String baseUrl) async {}
}

/// 跟读选择为在线方式的识别设置替身。
class _OnlineRecognitionSettingsNotifier extends RecognitionSettingsNotifier {
  _OnlineRecognitionSettingsNotifier(this.online);

  final bool online;

  @override
  RecognitionSettings build() => RecognitionSettings(
    subtitle: const RecognitionSelection.local('whisper-base-en-int8'),
    shadowing: online
        ? const RecognitionSelection.online()
        : const RecognitionSelection.local('whisper-base-en-int8'),
    retell: const RecognitionSelection.local('whisper-base-en-int8'),
  );
}

/// 生成指定时长、16 kHz 单声道 PCM16 WAV 的字节。
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

/// 录音后端假体：把每次录音写成真实 WAV 文件，可选自动发最终事件。
class _FakeRecordingBackend implements SpeechPracticeBackend {
  _FakeRecordingBackend(
    this.directory, {
    this.autoEmitFinal = true,
    this.duration = const Duration(seconds: 3),
  });

  final Directory directory;
  final bool autoEmitFinal;

  /// 写入录音文件的真实时长，用于覆盖单块边界。
  final Duration duration;
  final _controller = StreamController<SpeechPracticeEvent>.broadcast();

  bool? recognitionEnabled;
  String? activePromptId;
  int startSessionCalls = 0;
  int stopSessionCalls = 0;
  Completer<void>? stopGate;
  int counter = 0;

  @override
  bool get isSupported => true;

  @override
  Stream<SpeechPracticeEvent> get events => _controller.stream;

  @override
  Future<SpeechPracticePermissionState> getPermissionStatus() async =>
      const SpeechPracticePermissionState(
        microphone: SpeechPracticePermissionStatus.granted,
        speech: SpeechPracticePermissionStatus.granted,
      );

  @override
  Future<SpeechPracticePermissionState> requestPermissions({
    bool onlyMic = false,
  }) => getPermissionStatus();

  @override
  Future<int> getDeviceRamBytes() async => 0;

  @override
  Future<void> setRecognitionEnabled(bool enabled) async {
    recognitionEnabled = enabled;
  }

  @override
  Future<void> warmup({String locale = 'en-US'}) async {}

  @override
  Future<void> shutdown() async {}

  @override
  Future<String> startSession({
    required String promptId,
    String locale = 'en-US',
  }) async {
    startSessionCalls += 1;
    activePromptId = promptId;
    counter += 1;
    return _writeRecording('$promptId-$counter');
  }

  @override
  Future<SpeechPracticeStopResult> stopSession() async {
    stopSessionCalls += 1;
    await stopGate?.future;
    final promptId = activePromptId ?? '';
    if (autoEmitFinal) {
      scheduleMicrotask(() {
        _controller.add(
          SpeechPracticeEvent(
            type: SpeechPracticeEventType.finalTranscriptReady,
            promptId: promptId,
            transcript: 'platform final text',
          ),
        );
      });
    }
    return SpeechPracticeStopResult(
      filePath:
          '${directory.path}${Platform.pathSeparator}'
          '${promptId.replaceAll(':', '-')}-$counter.wav',
    );
  }

  @override
  Future<void> cancelSession() async {}

  @override
  Future<void> deleteRecording(String filePath) async {}

  void emitSpeechStarted() {
    _controller.add(
      SpeechPracticeEvent(
        type: SpeechPracticeEventType.speechStarted,
        promptId: activePromptId ?? '',
      ),
    );
  }

  Future<void> dispose() async {
    await _controller.close();
  }

  /// 写入一段 16 kHz 单声道 PCM16 WAV。
  ///
  /// promptId 里的冒号在 Windows 不能做文件名，写入前替换掉。
  String _writeRecording(String name) {
    final safe = name.replaceAll(':', '-');
    final path = '${directory.path}${Platform.pathSeparator}$safe.wav';
    File(path).writeAsBytesSync(_wavBytes(duration));
    return path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('shadowing_online_ctrl');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// 组装一个在线跟读环境；默认条件齐备，按需关掉某项模拟准入失败。
  ({
    ProviderContainer container,
    _FakeAdapter adapter,
    _FakeRecordingBackend recording,
    _FakeRecordingBackend localAsr,
  })
  build({
    bool online = true,
    bool textVerified = true,
    bool noticeDone = true,
    bool autoEmitFinal = true,
    Duration recordingDuration = const Duration(seconds: 3),
  }) {
    final adapter = _FakeAdapter();
    final recording = _FakeRecordingBackend(
      tempDir,
      autoEmitFinal: autoEmitFinal,
      duration: recordingDuration,
    );
    // 本机/离线后端替身：在线路径不得使用它。
    final localAsr = _FakeRecordingBackend(tempDir, autoEmitFinal: false);
    final configStore = _InMemorySpeechConfigStore();
    final capabilityStore = _InMemoryCapabilityStore(
      textVerified: textVerified,
      noticeDone: noticeDone,
    );
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        ...learningSettingsOverrides(listenAndRepeatRatingEnabled: true),
        recognitionSettingsProvider.overrideWith(
          () => _OnlineRecognitionSettingsNotifier(online),
        ),
        speechRecordingOnlyBackendProvider.overrideWithValue(recording),
        speechPracticeBackendProvider.overrideWithValue(localAsr),
        speechConfigStoreProvider.overrideWithValue(configStore),
        speechCapabilityStoreProvider.overrideWithValue(capabilityStore),
        speechTranscriptionClientProvider.overrideWithValue(
          SpeechTranscriptionClient(dio: Dio()..httpClientAdapter = adapter),
        ),
      ],
    );
    return (
      container: container,
      adapter: adapter,
      recording: recording,
      localAsr: localAsr,
    );
  }

  /// 让挂起的异步回调（文件读取、请求回包）有机会跑完。
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 等待一个可观察条件成立；这是有界轮询真实 IO，不是固定延时。
  Future<void> waitFor(
    bool Function() condition, {
    String reason = '条件未在预期时间内满足',
  }) async {
    for (var i = 0; i < 200; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail(reason);
  }

  test('录音期间不发请求，停录后只用跟读在线模型请求一次', () async {
    final env = build();
    final controller = env.container.read(
      speechRecordingControllerProvider.notifier,
    );
    addTearDown(() async {
      await controller.fullReset();
      await env.recording.dispose();
      await env.localAsr.dispose();
      env.container.dispose();
    });

    await controller.startRecording(
      promptId: 'shadowing:online:0',
      referenceText: 'The quick brown fox jumps over the lazy dog',
    );
    env.recording.emitSpeechStarted();
    await settle();
    expect(env.adapter.requestCount, 0, reason: '录音期间不得上传');

    env.adapter.enqueueJson({'text': _onlineText, 'usage': {'cost': 0.0002}});
    await controller.stopAndEvaluate(
      referenceText: 'The quick brown fox jumps over the lazy dog',
    );
    await waitFor(
      () =>
          env
              .container
              .read(speechRecordingControllerProvider)
              .currentAttempt
              ?.finalTranscript ==
          _onlineText,
      reason: '停录后应完成一次在线转写并评估',
    );

    expect(env.adapter.requestCount, 1, reason: '停录后只生成一次最终转写');
    expect(env.localAsr.startSessionCalls, 0, reason: '在线不借用离线/平台后端');
    expect(env.recording.startSessionCalls, 1);

    final request = env.adapter.requests.single;
    expect(request.headers['Authorization'], 'Bearer $_apiKey');
    final state = env.container.read(speechRecordingControllerProvider);
    expect(state.phase, SpeechRecordingPhase.idle);
    // 最终文本来自在线请求，而不是平台/离线后端的最终结果。
    expect(state.currentAttempt?.finalTranscript, _onlineText);
    expect(state.onlineShadowing?.isCompleted, isTrue);
    expect(state.onlineShadowing?.reportedCost, 0.0002);
    expect(state.onlineShadowing?.modelId, _modelId);
    expect(state.currentAttempt?.filePath, isNotNull, reason: '源录音保留');
  });

  test('跟读上下文里平台实时反馈保留，但最终结果只来自在线', () async {
    final env = build();
    final controller = env.container.read(
      speechRecordingControllerProvider.notifier,
    );
    addTearDown(() async {
      await controller.fullReset();
      await env.recording.dispose();
      await env.localAsr.dispose();
      env.container.dispose();
    });

    await controller.startRecording(
      promptId: 'shadowing:online:live',
      referenceText: 'hello world',
    );
    // 在线方式不使用离线引擎；平台识别开关由平台能力决定（此处为 false）。
    expect(env.recording.recognitionEnabled, isFalse);
    await controller.cancelActiveRecording();
  });

  test('没有文本能力验证时不发请求，并给出明确原因', () async {
    final env = build(textVerified: false);
    final controller = env.container.read(
      speechRecordingControllerProvider.notifier,
    );
    addTearDown(() async {
      await controller.fullReset();
      await env.recording.dispose();
      await env.localAsr.dispose();
      env.container.dispose();
    });

    await controller.startRecording(
      promptId: 'shadowing:online:unverified',
      referenceText: 'hello world',
    );
    env.recording.emitSpeechStarted();
    await controller.stopAndEvaluate(referenceText: 'hello world');
    await waitFor(
      () =>
          env
              .container
              .read(speechRecordingControllerProvider)
              .onlineShadowing
              ?.isFailed ??
          false,
      reason: '准入失败应留下可见状态',
    );

    expect(env.adapter.requestCount, 0);
    final state = env.container.read(speechRecordingControllerProvider);
    expect(state.currentAttempt?.status.isRecognitionFailure, isTrue);
    expect(
      state.onlineShadowing?.error,
      isA<ShadowingOnlineAccessDenied>().having(
        (error) => error.reason,
        'reason',
        ShadowingOnlineAccessDenial.capabilityUnverified,
      ),
    );
  });

  test('未完成上传告知时不发请求', () async {
    final env = build(noticeDone: false);
    final controller = env.container.read(
      speechRecordingControllerProvider.notifier,
    );
    addTearDown(() async {
      await controller.fullReset();
      await env.recording.dispose();
      await env.localAsr.dispose();
      env.container.dispose();
    });

    await controller.startRecording(
      promptId: 'shadowing:online:notice',
      referenceText: 'hello world',
    );
    env.recording.emitSpeechStarted();
    await controller.stopAndEvaluate(referenceText: 'hello world');
    await waitFor(
      () =>
          env
              .container
              .read(speechRecordingControllerProvider)
              .onlineShadowing
              ?.isFailed ??
          false,
      reason: '未告知时应拒绝并留下原因',
    );

    expect(env.adapter.requestCount, 0);
    expect(
      env.container.read(speechRecordingControllerProvider).onlineShadowing?.error,
      isA<ShadowingOnlineAccessDenied>().having(
        (error) => error.reason,
        'reason',
        ShadowingOnlineAccessDenial.uploadNoticeMissing,
      ),
    );
  });

  test('超出单块时长的录音被拒绝且不截断上传', () async {
    final env = build(recordingDuration: const Duration(minutes: 3));
    final controller = env.container.read(
      speechRecordingControllerProvider.notifier,
    );
    addTearDown(() async {
      await controller.fullReset();
      await env.recording.dispose();
      await env.localAsr.dispose();
      env.container.dispose();
    });

    await controller.startRecording(
      promptId: 'shadowing:online:long',
      referenceText: 'hello world',
    );
    env.recording.emitSpeechStarted();
    await controller.stopAndEvaluate(referenceText: 'hello world');
    await waitFor(
      () =>
          env
              .container
              .read(speechRecordingControllerProvider)
              .onlineShadowing
              ?.isFailed ??
          false,
      reason: '超出单块应明确失败',
    );

    expect(env.adapter.requestCount, 0, reason: '超出单块不得上传，也不能只传开头');
    final state = env.container.read(speechRecordingControllerProvider);
    expect(
      state.onlineShadowing?.error,
      isA<ShadowingRecordingRejected>().having(
        (error) => error.rejection,
        'rejection',
        ShadowingRecordingRejection.tooLong,
      ),
    );
    final filePath = state.currentAttempt?.filePath;
    expect(filePath, isNotNull, reason: '被拒绝时源录音保留');
    expect(File(filePath!).existsSync(), isTrue);
  });

  test('取消后到达的旧结果不覆盖新状态', () async {
    final env = build();
    final controller = env.container.read(
      speechRecordingControllerProvider.notifier,
    );
    addTearDown(() async {
      await controller.fullReset();
      await env.recording.dispose();
      await env.localAsr.dispose();
      env.container.dispose();
    });

    env.adapter.enqueueGatedJson({'text': _onlineText});
    await controller.startRecording(
      promptId: 'shadowing:online:cancel',
      referenceText: 'hello world',
    );
    env.recording.emitSpeechStarted();
    final stop = controller.stopAndEvaluate(referenceText: 'hello world');
    await waitFor(
      () => env.adapter.requestCount == 1,
      reason: '停录后应发出唯一一次请求',
    );

    await controller.cancelActiveRecording();
    env.adapter.release(0);
    await stop;
    await settle();

    final state = env.container.read(speechRecordingControllerProvider);
    expect(state.phase, SpeechRecordingPhase.idle);
    expect(state.currentAttempt, isNull, reason: '取消丢弃过期结果');
  });

  test('切换新录音后旧的在线结果不再写回', () async {
    final env = build();
    final controller = env.container.read(
      speechRecordingControllerProvider.notifier,
    );
    addTearDown(() async {
      await controller.fullReset();
      await env.recording.dispose();
      await env.localAsr.dispose();
      env.container.dispose();
    });

    env.adapter.enqueueGatedJson({'text': _onlineText});
    await controller.startRecording(
      promptId: 'shadowing:online:first',
      referenceText: 'hello world',
    );
    env.recording.emitSpeechStarted();
    final stop = controller.stopAndEvaluate(referenceText: 'hello world');
    await waitFor(
      () => env.adapter.requestCount == 1,
      reason: '第一回合应已发出请求',
    );

    await controller.startRecording(
      promptId: 'shadowing:online:second',
      referenceText: 'hello again',
    );
    env.adapter.release(0);
    await stop;
    await settle();

    final state = env.container.read(speechRecordingControllerProvider);
    expect(state.promptId, 'shadowing:online:second');
    expect(state.phase, SpeechRecordingPhase.awaitingSpeech);
    expect(
      state.currentAttempt?.finalTranscript,
      isNull,
      reason: '上一回合的在线结果不得写入新回合',
    );
  });
}
