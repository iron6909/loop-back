/// 用途识别选择：三用途独立、旧偏好迁移、系统识别可用范围与在途任务取消。
library;

import 'package:echo_loop/features/onboarding_survey/providers/onboarding_survey_provider.dart';
import 'package:echo_loop/models/recognition_selection.dart';
import 'package:echo_loop/providers/local_transcription_model_provider.dart';
import 'package:echo_loop/providers/offline_asr_settings_provider.dart';
import 'package:echo_loop/providers/recognition_settings_provider.dart';
import 'package:echo_loop/services/asr/asr_model_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mock_providers.dart';

const _tiny = 'whisper-tiny-en-int8';
const _base = 'whisper-base-en-int8';
const _small = 'whisper-small-en-int8';

AsrModelInfo _model(String id) =>
    availableModels.firstWhere((model) => model.id == id);

/// 记录写入的可控离线 ASR 设置，避免真实下载与引擎初始化。
class _FakeOfflineAsrNotifier extends OfflineAsrSettingsNotifier {
  _FakeOfflineAsrNotifier(this._initial);

  final OfflineAsrSettingsState _initial;
  final List<String> selectedModelIds = [];
  final List<AsrBackend> backends = [];

  @override
  OfflineAsrSettingsState build() => _initial;

  @override
  Future<void> selectModel(AsrModelInfo model) async {
    selectedModelIds.add(model.id);
    state = state.copyWith(selectedModel: model);
  }

  @override
  Future<void> setBackend(AsrBackend backend) async {
    backends.add(backend);
    state = state.copyWith(backend: backend);
  }
}

Future<ProviderContainer> _container({
  Map<String, Object> prefs = const {},
  bool applePlatform = true,
  AsrBackend? defaultBackend,
  _FakeOfflineAsrNotifier? asrNotifier,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sp),
      recommendedAsrModelProvider.overrideWithValue(_model(_base)),
      systemRecognitionPlatformProvider.overrideWithValue(applePlatform),
      if (defaultBackend != null)
        initialOfflineAsrSettingsStateProvider.overrideWithValue(
          OfflineAsrSettingsState(
            backend: defaultBackend,
            recommendedModel: _model(_base),
          ),
        ),
      if (asrNotifier != null)
        offlineAsrSettingsProvider.overrideWith(() => asrNotifier),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('三用途独立选择', () {
    test('各自保存方式与模型，改动互不覆盖', () async {
      final asr = _FakeOfflineAsrNotifier(
        OfflineAsrSettingsState(
          backend: AsrBackend.offline,
          selectedModel: _model(_base),
          recommendedModel: _model(_base),
        ),
      );
      final container = await _container(
        prefs: {localTranscriptionModelKey: _small},
        asrNotifier: asr,
      );
      addTearDown(container.dispose);
      final notifier = container.read(recognitionSettingsProvider.notifier);

      final initial = container.read(recognitionSettingsProvider);
      expect(initial.subtitle.localModelId, _small);
      expect(initial.shadowing.localModelId, _base);
      expect(initial.shadowing.mode, RecognitionMode.local);
      // 复述首次建立独立偏好时继承升级前实际字幕模型。
      expect(initial.retell.localModelId, _small);
      expect(initial.retell.mode, RecognitionMode.local);

      await notifier.change(
        purpose: RecognitionPurpose.shadowing,
        selection: const RecognitionSelection.local(_tiny),
      );
      var state = container.read(recognitionSettingsProvider);
      expect(state.shadowing.localModelId, _tiny);
      expect(state.subtitle.localModelId, _small);
      expect(state.retell.localModelId, _small);
      expect(asr.selectedModelIds, [_tiny]);

      await notifier.change(
        purpose: RecognitionPurpose.retell,
        selection: const RecognitionSelection.local(_base),
      );
      state = container.read(recognitionSettingsProvider);
      expect(state.retell.localModelId, _base);
      expect(state.subtitle.localModelId, _small);
      expect(state.shadowing.localModelId, _tiny);

      await notifier.change(
        purpose: RecognitionPurpose.subtitle,
        selection: const RecognitionSelection.local(_base),
      );
      state = container.read(recognitionSettingsProvider);
      expect(state.subtitle.localModelId, _base);
      // 复述已建立自己的偏好，不再跟随字幕模型。
      expect(state.retell.localModelId, _base);
      expect(
        container.read(localTranscriptionModelProvider).id,
        _base,
        reason: '字幕入口与设置页共用同一份状态',
      );
    });

    test('复述偏好被快照到本机偏好，重启后不随字幕模型漂移', () async {
      SharedPreferences.setMockInitialValues({
        localTranscriptionModelKey: _small,
      });
      final sp = await SharedPreferences.getInstance();
      final first = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(sp),
          recommendedAsrModelProvider.overrideWithValue(_model(_small)),
          systemRecognitionPlatformProvider.overrideWithValue(true),
        ],
      );
      expect(
        first.read(recognitionSettingsProvider).retell.localModelId,
        _small,
      );
      expect(sp.getString(retellModelPrefsKey), _small);
      first.dispose();

      final second = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(sp),
          recommendedAsrModelProvider.overrideWithValue(_model(_base)),
          systemRecognitionPlatformProvider.overrideWithValue(true),
        ],
      );
      addTearDown(second.dispose);
      await second
          .read(recognitionSettingsProvider.notifier)
          .change(
            purpose: RecognitionPurpose.subtitle,
            selection: const RecognitionSelection.local(_tiny),
          );
      expect(
        second.read(recognitionSettingsProvider).retell.localModelId,
        _small,
      );
    });
  });

  group('旧偏好与平台默认', () {
    test('有效旧偏好优先：跟读沿用旧后端，字幕沿用旧模型', () async {
      final container = await _container(
        prefs: {
          'offline_asr_backend': 'offline',
          'offline_asr_selected_model_id': _small,
          localTranscriptionModelKey: _base,
        },
      );
      addTearDown(container.dispose);

      final state = container.read(recognitionSettingsProvider);
      expect(state.shadowing.mode, RecognitionMode.local);
      expect(state.shadowing.localModelId, _small);
      expect(state.subtitle.localModelId, _base);
      expect(state.retell.localModelId, _base);
    });

    test('旧后端为平台识别时跟读保留系统识别', () async {
      final container = await _container(
        prefs: {'offline_asr_backend': 'platform'},
      );
      addTearDown(container.dispose);

      expect(
        container.read(recognitionSettingsProvider).shadowing.mode,
        RecognitionMode.system,
      );
    });

    test('无旧偏好时 Android 跟读默认本机、Apple 跟读保持平台识别', () async {
      final android = await _container(defaultBackend: AsrBackend.offline);
      addTearDown(android.dispose);
      expect(
        android.read(recognitionSettingsProvider).shadowing.mode,
        RecognitionMode.local,
      );

      final apple = await _container(defaultBackend: AsrBackend.platform);
      addTearDown(apple.dispose);
      expect(
        apple.read(recognitionSettingsProvider).shadowing.mode,
        RecognitionMode.system,
      );
    });

    test('新装字幕与复述为本机方式', () async {
      final container = await _container(defaultBackend: AsrBackend.platform);
      addTearDown(container.dispose);

      final state = container.read(recognitionSettingsProvider);
      expect(state.subtitle.mode, RecognitionMode.local);
      expect(state.retell.mode, RecognitionMode.local);
    });
  });

  group('可选方式', () {
    test('系统识别只在受支持的平台与用途出现，在线按用途条件出现', () {
      expect(
        availableRecognitionModes(
          RecognitionPurpose.subtitle,
          systemSupported: true,
        ),
        [RecognitionMode.local],
        reason: '字幕需要片段时间戳，系统识别不足以生成字幕',
      );
      expect(
        availableRecognitionModes(
          RecognitionPurpose.shadowing,
          systemSupported: false,
        ),
        [RecognitionMode.local],
        reason: '条件未就绪时在线不作为可选方式',
      );
      expect(
        availableRecognitionModes(
          RecognitionPurpose.shadowing,
          systemSupported: true,
        ),
        [RecognitionMode.local, RecognitionMode.system],
      );
      expect(
        availableRecognitionModes(
          RecognitionPurpose.shadowing,
          systemSupported: true,
          onlineAvailable: true,
        ),
        [RecognitionMode.local, RecognitionMode.system, RecognitionMode.online],
      );
      expect(
        availableRecognitionModes(
          RecognitionPurpose.shadowing,
          systemSupported: false,
          onlineAvailable: true,
        ),
        [RecognitionMode.local, RecognitionMode.online],
      );
      expect(
        availableRecognitionModes(
          RecognitionPurpose.retell,
          systemSupported: true,
          onlineAvailable: true,
        ),
        [RecognitionMode.local, RecognitionMode.system, RecognitionMode.online],
        reason: '复述自己的在线方式通过文本能力验证后才出现',
      );
      expect(
        availableRecognitionModes(
          RecognitionPurpose.retell,
          systemSupported: true,
        ),
        [RecognitionMode.local, RecognitionMode.system],
        reason: '未就绪时不出现在线方式',
      );
      expect(RecognitionMode.values, hasLength(3));
    });

    test('跟读选在线被持久化，且不改变离线 ASR 档位', () async {
      final asr = _FakeOfflineAsrNotifier(
        OfflineAsrSettingsState(
          backend: AsrBackend.offline,
          selectedModel: _model(_base),
          recommendedModel: _model(_base),
        ),
      );
      final container = await _container(asrNotifier: asr);
      addTearDown(container.dispose);

      final result = await container
          .read(recognitionSettingsProvider.notifier)
          .change(
            purpose: RecognitionPurpose.shadowing,
            selection: const RecognitionSelection.online(),
          );

      expect(result.applied, isTrue);
      expect(
        container.read(recognitionSettingsProvider).shadowing.mode,
        RecognitionMode.online,
      );
      expect(asr.backends, isEmpty, reason: '在线不切换本机后端');
      expect(asr.selectedModelIds, isEmpty, reason: '在线不触发模型下载/初始化');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(shadowingOnlinePrefsKey), 'online');

      await container
          .read(recognitionSettingsProvider.notifier)
          .change(
            purpose: RecognitionPurpose.shadowing,
            selection: const RecognitionSelection.local(_base),
          );
      expect(
        container.read(recognitionSettingsProvider).shadowing.mode,
        RecognitionMode.local,
      );
      expect(prefs.getString(shadowingOnlinePrefsKey), isNull);
    });

    test('字幕只有本机与在线两种方式，在线需通过片段时间戳能力', () {
      expect(
        availableRecognitionModes(
          RecognitionPurpose.subtitle,
          systemSupported: true,
        ),
        [RecognitionMode.local],
        reason: '在线未通过能力验证时不作为可选方式',
      );
      expect(
        availableRecognitionModes(
          RecognitionPurpose.subtitle,
          systemSupported: true,
          onlineAvailable: true,
        ),
        [RecognitionMode.local, RecognitionMode.online],
        reason: '字幕可选在线，但从不提供系统识别',
      );
    });
  });

  test('字幕在线方式被持久化并在重启后恢复', () async {
    final container = await _container(
      prefs: {localTranscriptionModelKey: _small},
    );
    addTearDown(container.dispose);

    await container
        .read(recognitionSettingsProvider.notifier)
        .change(
          purpose: RecognitionPurpose.subtitle,
          selection: const RecognitionSelection.online(),
        );
    expect(
      container.read(recognitionSettingsProvider).subtitle.mode,
      RecognitionMode.online,
    );

    final prefs = await SharedPreferences.getInstance();
    final restarted = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recommendedAsrModelProvider.overrideWithValue(_model(_base)),
      ],
    );
    addTearDown(restarted.dispose);
    final restored = restarted.read(recognitionSettingsProvider).subtitle;
    expect(restored.mode, RecognitionMode.online);
    // 切回本机时仍保留大小模型偏好。
    expect(restored.localModelId, _small);
  });

  group('影响在途任务的选择变更', () {
    RecognitionInFlightTask inFlightTask(
      RecognitionPurpose purpose,
      List<RecognitionPurpose> cancelled,
    ) => RecognitionInFlightTask(
      purpose: purpose,
      label: purpose.name,
      onCancel: () async => cancelled.add(purpose),
    );

    test('有受影响任务时先返回确认，不改变配置也不取消任务', () async {
      final cancelled = <RecognitionPurpose>[];
      final container = await _container(
        prefs: {localTranscriptionModelKey: _small},
      );
      addTearDown(container.dispose);
      final registry = container.read(recognitionInFlightTasksProvider);
      final task = inFlightTask(RecognitionPurpose.subtitle, cancelled);
      registry.register(task);

      final result = await container
          .read(recognitionSettingsProvider.notifier)
          .change(
            purpose: RecognitionPurpose.subtitle,
            selection: const RecognitionSelection.local(_base),
          );

      expect(result.applied, isFalse);
      expect(result.affectedTasks, [task]);
      expect(cancelled, isEmpty);
      expect(
        container.read(recognitionSettingsProvider).subtitle.localModelId,
        _small,
      );
      expect(registry.pendingFor(RecognitionPurpose.subtitle), [task]);
    });

    test('接受后取消受影响任务并应用变更，无关用途不被取消', () async {
      final cancelled = <RecognitionPurpose>[];
      final container = await _container(
        prefs: {localTranscriptionModelKey: _small},
      );
      addTearDown(container.dispose);
      final registry = container.read(recognitionInFlightTasksProvider);
      final subtitleTask = inFlightTask(RecognitionPurpose.subtitle, cancelled);
      final retellTask = inFlightTask(RecognitionPurpose.retell, cancelled);
      registry.register(subtitleTask);
      registry.register(retellTask);

      final result = await container
          .read(recognitionSettingsProvider.notifier)
          .change(
            purpose: RecognitionPurpose.subtitle,
            selection: const RecognitionSelection.local(_base),
            cancelInFlight: true,
          );

      expect(result.applied, isTrue);
      expect(cancelled, [RecognitionPurpose.subtitle]);
      expect(retellTask.isCancelled, isFalse);
      expect(
        container.read(recognitionSettingsProvider).subtitle.localModelId,
        _base,
      );
      expect(registry.pendingFor(RecognitionPurpose.subtitle), isEmpty);
    });

    test('复述方式变更被持久化并在重启后恢复', () async {
      final container = await _container();
      addTearDown(container.dispose);

      await container
          .read(recognitionSettingsProvider.notifier)
          .change(
            purpose: RecognitionPurpose.retell,
            selection: const RecognitionSelection.system(),
          );
      expect(
        container.read(recognitionSettingsProvider).retell.mode,
        RecognitionMode.system,
      );

      final prefs = await SharedPreferences.getInstance();
      final restarted = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recommendedAsrModelProvider.overrideWithValue(_model(_base)),
          systemRecognitionPlatformProvider.overrideWithValue(true),
        ],
      );
      addTearDown(restarted.dispose);
      expect(
        restarted.read(recognitionSettingsProvider).retell.mode,
        RecognitionMode.system,
      );
    });
  });

  group('语音配置变更的在途任务', () {
    RecognitionInFlightTask task(
      String name,
      RecognitionPurpose purpose,
      List<String> cancelled, {
      bool usesOnlineSpeech = true,
    }) => RecognitionInFlightTask(
      purpose: purpose,
      label: name,
      usesOnlineSpeech: usesOnlineSpeech,
      onCancel: () async => cancelled.add(name),
    );

    test('只取指定用途内绑定在线配置的任务', () {
      final cancelled = <String>[];
      final registry = RecognitionInFlightRegistry();
      final subtitleOnline = task(
        'subtitle-online',
        RecognitionPurpose.subtitle,
        cancelled,
      );
      final retellOnline = task(
        'retell-online',
        RecognitionPurpose.retell,
        cancelled,
      );
      final subtitleLocal = task(
        'subtitle-local',
        RecognitionPurpose.subtitle,
        cancelled,
        usesOnlineSpeech: false,
      );
      registry.register(subtitleOnline);
      registry.register(retellOnline);
      registry.register(subtitleLocal);

      expect(registry.pendingOnline({RecognitionPurpose.subtitle}), [
        subtitleOnline,
      ], reason: '只改字幕在线模型：复述与本机字幕任务都不受影响');
      expect(registry.pendingOnline(RecognitionPurpose.values.toSet()), [
        subtitleOnline,
        retellOnline,
      ]);
    });

    test('取消后执行任务自己的取消入口并移出登记处', () async {
      final cancelled = <String>[];
      final registry = RecognitionInFlightRegistry();
      final subtitleOnline = task(
        'subtitle-online',
        RecognitionPurpose.subtitle,
        cancelled,
      );
      final retellOnline = task(
        'retell-online',
        RecognitionPurpose.retell,
        cancelled,
      );
      registry.register(subtitleOnline);
      registry.register(retellOnline);

      await registry.cancel([subtitleOnline]);

      expect(cancelled, ['subtitle-online']);
      expect(subtitleOnline.isCancelled, isTrue);
      expect(registry.pendingFor(RecognitionPurpose.subtitle), isEmpty);
      expect(registry.pendingFor(RecognitionPurpose.retell), [retellOnline]);
    });
  });
}
