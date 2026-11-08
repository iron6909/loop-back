import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_loop/models/recognition_selection.dart';
import 'package:echo_loop/models/speech_practice_models.dart';
import 'package:echo_loop/providers/learning_settings_provider.dart';
import 'package:echo_loop/providers/offline_asr_settings_provider.dart';
import 'package:echo_loop/providers/recognition_settings_provider.dart';
import 'package:echo_loop/providers/retell_recording_controller_provider.dart';
import 'package:echo_loop/providers/retell_review_evaluation_provider.dart';
import 'package:echo_loop/services/speech/practice_chunk_transcriber.dart';
import 'package:echo_loop/services/speech/speech_config.dart';
import 'package:echo_loop/services/speech_practice_platform.dart';

import '../helpers/mock_providers.dart';

const _testAsrModel = AsrModelInfo(
  id: 'test-model',
  displayName: 'Test Model',
  type: AsrModelType.moonshine,
);

final _testAsrSettings = OfflineAsrSettingsState(
  enabled: true,
  backend: AsrBackend.platform,
  recommendedModel: _testAsrModel,
);

class _FakeOfflineAsrSettingsNotifier extends OfflineAsrSettingsNotifier {
  @override
  OfflineAsrSettingsState build() => _testAsrSettings;
}

/// 固定用途识别选择，避免用例依赖偏好读写。
class _FixedRecognitionSettings extends RecognitionSettingsNotifier {
  _FixedRecognitionSettings(this._fixed);

  final RecognitionSettings _fixed;

  @override
  RecognitionSettings build() => _fixed;
}

/// 现有用例验证平台实时识别路径，因此固定为系统方式。
const _systemRecognition = RecognitionSettings(
  subtitle: RecognitionSelection.local('subtitle-model'),
  shadowing: RecognitionSelection.local('shadowing-model'),
  retell: RecognitionSelection.system(),
);

/// 复述自己的本机档位与字幕、跟读都不同，用来验证不再借用字幕模型。
const _localRecognition = RecognitionSettings(
  subtitle: RecognitionSelection.local('subtitle-model'),
  shadowing: RecognitionSelection.local('shadowing-model'),
  retell: RecognitionSelection.local('retell-model'),
);

/// 复述走在线方式；实际服务与模型由语音配置决定。
const _onlineRecognition = RecognitionSettings(
  subtitle: RecognitionSelection.local('subtitle-model'),
  shadowing: RecognitionSelection.local('shadowing-model'),
  retell: RecognitionSelection.online(),
);

const _onlineRetellModel = 'openai/whisper-retell';

/// 复述在线转写后记录的实际识别身份：服务类型、根地址与复述自己的在线模型。
final _onlineRetellIdentity = onlineRecognitionIdentity(
  const SpeechConfig(
    kind: SpeechProviderKind.openrouter,
    baseUrl: 'https://openrouter.ai/api/v1',
  ),
  _onlineRetellModel,
);

/// 复述在线转写替身：记录被转写的录音路径，按用例返回结果或失败。
class _FakeRetellOnline implements RetellOnlineTranscriber {
  _FakeRetellOnline(this._run);
  final Future<RetellOnlineTranscript> Function(String path) _run;

  @override
  Future<RetellOnlineTranscript> call(
    String filePath, {
    CancelToken? cancelToken,
  }) => _run(filePath);

  @override
  Future<void> discard() async {}
}

class _FakeSpeechPracticeBackend implements SpeechPracticeBackend {
  final _controller = StreamController<SpeechPracticeEvent>.broadcast();
  final Completer<void> warmupStarted = Completer<void>();
  final Completer<void> warmupGate = Completer<void>();
  bool blockWarmup = false;
  String? activePromptId;
  int counter = 0;
  bool failStopSession = false;
  bool emitFinalTranscript = true;
  int cancelSessionCalls = 0;
  int shutdownCalls = 0;
  final List<String> deletedRecordings = [];

  @override
  bool get isSupported => true;

  @override
  Stream<SpeechPracticeEvent> get events => _controller.stream;

  @override
  Future<SpeechPracticePermissionState> getPermissionStatus() async {
    return const SpeechPracticePermissionState(
      microphone: SpeechPracticePermissionStatus.granted,
      speech: SpeechPracticePermissionStatus.granted,
    );
  }

  @override
  Future<SpeechPracticePermissionState> requestPermissions({
    bool onlyMic = false,
  }) {
    return getPermissionStatus();
  }

  @override
  Future<void> warmup({String locale = 'en-US'}) async {
    if (!warmupStarted.isCompleted) warmupStarted.complete();
    if (blockWarmup) await warmupGate.future;
  }

  @override
  Future<int> getDeviceRamBytes() async => 0;

  @override
  Future<void> setRecognitionEnabled(bool enabled) async {}

  @override
  Future<void> shutdown() async {
    shutdownCalls += 1;
  }

  @override
  Future<String> startSession({
    required String promptId,
    String locale = 'en-US',
  }) async {
    activePromptId = promptId;
    counter += 1;
    return '/tmp/$promptId-$counter.caf';
  }

  @override
  Future<SpeechPracticeStopResult> stopSession() async {
    if (failStopSession) {
      throw StateError('stop failed');
    }
    final promptId = activePromptId ?? 'retell:a1:0';
    if (emitFinalTranscript) {
      scheduleMicrotask(() {
        _controller.add(
          SpeechPracticeEvent(
            type: SpeechPracticeEventType.finalTranscriptReady,
            promptId: promptId,
            transcript: 'retell transcript',
          ),
        );
      });
    }
    return SpeechPracticeStopResult(filePath: '/tmp/$promptId-$counter.caf');
  }

  @override
  Future<void> cancelSession() async {
    cancelSessionCalls += 1;
    activePromptId = null;
  }

  @override
  Future<void> deleteRecording(String filePath) async {
    deletedRecordings.add(filePath);
  }

  void emitPartial(String transcript) {
    _controller.add(
      SpeechPracticeEvent(
        type: SpeechPracticeEventType.partialTranscriptUpdated,
        promptId: activePromptId ?? 'retell:a1:0',
        transcript: transcript,
      ),
    );
  }

  void emitSpeechStarted() {
    _controller.add(
      SpeechPracticeEvent(
        type: SpeechPracticeEventType.speechStarted,
        promptId: activePromptId ?? 'retell:a1:0',
      ),
    );
  }

  void emitSilence(Duration duration) {
    _controller.add(
      SpeechPracticeEvent(
        type: SpeechPracticeEventType.silenceProgress,
        promptId: activePromptId ?? 'retell:a1:0',
        silenceDuration: duration,
      ),
    );
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> disposeTestResources({
    required RetellRecordingController controller,
    required ProviderContainer container,
    required _FakeSpeechPracticeBackend backend,
  }) async {
    // ProviderContainer.dispose() 不等待 Notifier 的异步 onDispose；先显式
    // 收尾录音会话和事件订阅，避免下一个测试与旧 RecordingService 交叠。
    await controller.fullReset();
    await backend.dispose();
    container.dispose();
  }

  test('非复述活动会话进入后台不会留下等待开口超时标记', () async {
    final backend = _FakeSpeechPracticeBackend();
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_systemRecognition),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );

    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

    expect(controller.state.awaitingSpeechTimedOut, isFalse);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  test('复述播放器通知进入后台后设置超时标记以阻止自动录音', () async {
    final backend = _FakeSpeechPracticeBackend();
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_systemRecognition),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );

    await controller.handleRetellSessionBackground();

    expect(controller.state.awaitingSpeechTimedOut, isTrue);

    await controller.clearRecording();
  });

  test('后台进入时会取消正在录音的回合', () async {
    final backend = _FakeSpeechPracticeBackend();
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_systemRecognition),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'first paragraph',
    );

    await controller.handleRetellSessionBackground();

    expect(backend.cancelSessionCalls, 1);
    expect(backend.shutdownCalls, 1);
    expect(controller.state.phase, RetellRecordingPhase.idle);
    expect(controller.state.awaitingSpeechTimedOut, isTrue);
  });

  test('后台进入会取消处理中识别并丢弃迟到结果', () async {
    final backend = _FakeSpeechPracticeBackend()..emitFinalTranscript = false;
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_systemRecognition),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );
    final processingStarted = Completer<void>();
    final subscription = container.listen(retellRecordingControllerProvider, (
      previous,
      next,
    ) {
      if (next.phase == RetellRecordingPhase.processing &&
          !processingStarted.isCompleted) {
        processingStarted.complete();
      }
    });
    addTearDown(subscription.close);

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'first paragraph',
    );
    final stopping = controller.stopAndEvaluate(
      referenceText: 'first paragraph',
    );
    await processingStarted.future;
    final shutdownCallsBeforeBackground = backend.shutdownCalls;

    await controller.handleRetellSessionBackground();
    await stopping;

    expect(controller.state.phase, RetellRecordingPhase.idle);
    expect(controller.state.awaitingSpeechTimedOut, isTrue);
    expect(controller.state.currentAttempt, isNull);
    expect(backend.shutdownCalls, greaterThan(shutdownCallsBeforeBackground));
    expect(backend.deletedRecordings, ['/tmp/retell:a1:0-1.caf']);
  });

  test('后台取消尚未完成时的新录音等待旧启动收尾后再开始', () async {
    final backend = _FakeSpeechPracticeBackend()..blockWarmup = true;
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_systemRecognition),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );

    final oldStart = controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'first paragraph',
    );
    await backend.warmupStarted.future;

    final backgroundCancellation = controller.handleRetellSessionBackground();
    final newStart = controller.startRecording(
      promptId: 'retell:a1:1',
      referenceText: 'second paragraph',
    );
    backend.warmupGate.complete();
    await Future.wait([oldStart, backgroundCancellation, newStart]);

    expect(backend.activePromptId, 'retell:a1:1');
    expect(controller.state.promptId, 'retell:a1:1');
    expect(controller.state.phase, RetellRecordingPhase.recording);
    expect(controller.state.awaitingSpeechTimedOut, isFalse);
  });

  test('RetellRecordingController 在停止录音后触发有效录音时长回调', () async {
    final backend = _FakeSpeechPracticeBackend();
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_systemRecognition),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );
    Duration? recordedDuration;
    controller.setRecordingCompletionHandler((duration) {
      recordedDuration = duration;
    });

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'ask your professor today for authorization again',
    );

    backend.emitSpeechStarted();
    backend.emitPartial('ask your professor today');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    backend.emitSilence(const Duration(milliseconds: 100));

    await controller.stopAndEvaluate(
      referenceText: 'ask your professor today for authorization again',
    );

    expect(recordedDuration, isNotNull);
    expect(
      recordedDuration,
      greaterThanOrEqualTo(const Duration(milliseconds: 900)),
    );
  });

  test('启动中清理会取消旧段录音，后续段落可以独立启动', () async {
    final backend = _FakeSpeechPracticeBackend()..blockWarmup = true;
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_systemRecognition),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );

    final oldStart = controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'first paragraph',
    );
    await backend.warmupStarted.future;

    final clearing = controller.clearRecording();
    backend.warmupGate.complete();
    await clearing;
    await oldStart;

    expect(controller.state.phase, RetellRecordingPhase.idle);
    expect(backend.activePromptId, isNull);

    await controller.startRecording(
      promptId: 'retell:a1:1',
      referenceText: 'second paragraph',
    );

    expect(backend.activePromptId, 'retell:a1:1');
    expect(controller.state.promptId, 'retell:a1:1');
  });

  test('不同 prompt 不会加入旧段尚未完成的启动 future', () async {
    final backend = _FakeSpeechPracticeBackend()..blockWarmup = true;
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_systemRecognition),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );

    final oldStart = controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'first paragraph',
    );
    await backend.warmupStarted.future;
    final nextStart = controller.startRecording(
      promptId: 'retell:a1:1',
      referenceText: 'second paragraph',
    );
    backend.warmupGate.complete();
    await Future.wait([oldStart, nextStart]);

    expect(backend.activePromptId, 'retell:a1:1');
    expect(controller.state.promptId, 'retell:a1:1');
  });

  test('停止会话失败应显示通用错误而非设备不支持', () async {
    final backend = _FakeSpeechPracticeBackend()..failStopSession = true;
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_systemRecognition),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'first paragraph',
    );
    await controller.stopAndEvaluate(referenceText: 'first paragraph');

    expect(
      controller.state.currentAttempt?.status,
      SpeechPracticeAttemptStatus.error,
    );
    expect(
      controller.state.currentAttempt?.errorMessage,
      contains('stop failed'),
    );
  });

  test('RetellRecordingController 关闭复述评级时只保留录音并跳过转录评分', () async {
    final backend = _FakeSpeechPracticeBackend();
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(retellRatingEnabled: false),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_systemRecognition),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'ask your professor today for authorization again',
    );

    await controller.stopAndEvaluate(
      referenceText: 'ask your professor today for authorization again',
    );

    final attempt = container
        .read(retellRecordingControllerProvider)
        .currentAttempt;
    expect(attempt, isNotNull);
    expect(attempt!.filePath, isNotEmpty);
    expect(attempt.status, SpeechPracticeAttemptStatus.unavailable);
    expect(attempt.score, isNull);
    expect(attempt.finalTranscript, isNull);
    expect(attempt.transcriptSegments, isEmpty);
    expect(attempt.referenceSegments, isEmpty);
  });

  test('RetellRecordingController 取消录音不触发统计回调', () async {
    final backend = _FakeSpeechPracticeBackend();
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_systemRecognition),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );
    Duration? recordedDuration;
    controller.setRecordingCompletionHandler((duration) {
      recordedDuration = duration;
    });

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'ask your professor today',
    );
    await controller.cancelActiveRecording();

    expect(recordedDuration, isNull);
  });

  test('RetellRecordingController 停止录音失败不触发统计回调', () async {
    final backend = _FakeSpeechPracticeBackend()..failStopSession = true;
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_systemRecognition),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );
    Duration? recordedDuration;
    controller.setRecordingCompletionHandler((duration) {
      recordedDuration = duration;
    });

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'ask your professor today',
    );
    await controller.stopAndEvaluate(referenceText: 'ask your professor today');

    expect(recordedDuration, isNull);
  });

  test('本机方式在停止录音后按复述自己的模型转写并记录识别身份', () async {
    final backend = _FakeSpeechPracticeBackend();
    final transcribed = <String>[];
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_localRecognition),
        ),
        retellTranscriptProvider.overrideWithValue((path) async {
          transcribed.add(path);
          return 'own retell transcript';
        }),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'ask your professor today',
    );
    expect(
      container
          .read(recognitionInFlightTasksProvider)
          .pendingFor(RecognitionPurpose.retell),
      hasLength(1),
      reason: '录音中的复述任务要能被设置变更告知并取消',
    );

    await controller.stopAndEvaluate(referenceText: 'ask your professor today');

    final attempt = controller.state.currentAttempt;
    expect(transcribed, hasLength(1), reason: '按复述自己的模型转写录音文件');
    expect(attempt?.recognitionIdentity, 'local:retell-model');
    expect(
      attempt?.isRecognitionFailure,
      isFalse,
      reason: '本机转写成功时不应被判为识别失败',
    );
    expect(
      container
          .read(recognitionInFlightTasksProvider)
          .pendingFor(RecognitionPurpose.retell),
      isEmpty,
    );
  });

  test('系统方式使用平台实时结果并标记系统识别身份', () async {
    final backend = _FakeSpeechPracticeBackend();
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_systemRecognition),
        ),
        retellTranscriptProvider.overrideWithValue(
          (_) async => 'should not be used',
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'ask your professor today',
    );
    await controller.stopAndEvaluate(referenceText: 'ask your professor today');

    expect(controller.state.currentAttempt?.recognitionIdentity, 'system');
  });

  test('在线方式在停止录音后按复述自己的在线模型转写并记录实际识别身份', () async {
    final backend = _FakeSpeechPracticeBackend();
    final onlinePaths = <String>[];
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_onlineRecognition),
        ),
        // 在线方式不得回退到本机转写。
        retellTranscriptProvider.overrideWithValue(
          (_) async => throw StateError('在线方式不得借用本机转写'),
        ),
        retellOnlineTranscriptProvider.overrideWithValue(
          _FakeRetellOnline((path) async {
            onlinePaths.add(path);
            return RetellOnlineTranscript(
              text: 'ask your professor today',
              identity: _onlineRetellIdentity,
              modelId: _onlineRetellModel,
              serviceHost: 'openrouter.ai',
              reportedCost: 0.0002,
            );
          }),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'ask your professor today',
    );
    await controller.stopAndEvaluate(referenceText: 'ask your professor today');

    final attempt = controller.state.currentAttempt;
    expect(onlinePaths, hasLength(1), reason: '停录后只上传一次');
    expect(
      attempt?.recognitionIdentity,
      _onlineRetellIdentity,
      reason: '记录实际在线服务与模型，评估据此判断能否复用',
    );
    expect(attempt?.isRecognitionFailure, isFalse);
  });

  test('在线转写失败时不进入评分，保留录音并标记识别失败', () async {
    final backend = _FakeSpeechPracticeBackend();
    final container = ProviderContainer(
      overrides: [
        analyticsOverride(),
        initialLearningSettingsProvider.overrideWithValue(
          const LearningSettings(),
        ),
        speechPracticeBackendProvider.overrideWithValue(backend),
        recommendedAsrModelProvider.overrideWithValue(_testAsrModel),
        offlineAsrSettingsProvider.overrideWith(
          () => _FakeOfflineAsrSettingsNotifier(),
        ),
        recognitionSettingsProvider.overrideWith(
          () => _FixedRecognitionSettings(_onlineRecognition),
        ),
        retellTranscriptProvider.overrideWithValue(
          (_) async => throw StateError('在线方式不得借用本机转写'),
        ),
        // 长录音分块失败：停在失败块，可能已计费，源录音保留。
        retellOnlineTranscriptProvider.overrideWithValue(
          _FakeRetellOnline(
            (_) async => throw const PracticeChunkFailure(
              PracticeChunkFailureReason.requestFailed,
              mayHaveBeenCharged: true,
            ),
          ),
        ),
      ],
    );
    final controller = container.read(
      retellRecordingControllerProvider.notifier,
    );
    addTearDown(
      () => disposeTestResources(
        controller: controller,
        container: container,
        backend: backend,
      ),
    );

    await controller.startRecording(
      promptId: 'retell:a1:0',
      referenceText: 'ask your professor today',
    );
    await controller.stopAndEvaluate(referenceText: 'ask your professor today');

    final attempt = controller.state.currentAttempt;
    expect(attempt?.filePath, isNotNull, reason: '失败也要保留源录音');
    expect(attempt?.status, SpeechPracticeAttemptStatus.error);
    expect(attempt?.finalTranscript, isNull, reason: '没有文本就不能给评分');
  });
}
