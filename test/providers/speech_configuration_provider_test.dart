/// 在线语音配置状态：与文字 AI 分槽、保存串行、旧回调不污染新配置。
library;

import 'dart:async';

import 'package:loop_back/providers/shared_preferences_provider.dart';
import 'package:loop_back/models/recognition_selection.dart';
import 'package:loop_back/providers/offline_asr_settings_provider.dart';
import 'package:loop_back/providers/provider_configuration_provider.dart';
import 'package:loop_back/providers/recognition_settings_provider.dart';
import 'package:loop_back/providers/speech_configuration_provider.dart';
import 'package:loop_back/services/asr/asr_model_manager.dart';
import 'package:loop_back/services/provider/provider_config.dart';
import 'package:loop_back/services/provider/provider_config_store.dart';
import 'package:loop_back/services/speech/speech_config.dart';
import 'package:loop_back/services/speech/speech_config_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mock_providers.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

/// 取 mock 调用里的安全存储 key，避免把未校验的 dynamic 直接当 key 使用。
String _secureKeyName(Invocation invocation) {
  final name = invocation.namedArguments[#key];
  if (name is! String) throw StateError('安全存储缺少 key 名称');
  return name;
}

const _sentinelSpeechKey = 'spk-4b7d';
const _sentinelTextKey = 'txt-0c21';
const _base = 'whisper-base-en-int8';

AsrModelInfo _model(String id) =>
    availableModels.firstWhere((model) => model.id == id);

/// 记录写入的可控离线 ASR 设置，避免真实下载与引擎初始化。
class _FakeOfflineAsrNotifier extends OfflineAsrSettingsNotifier {
  @override
  OfflineAsrSettingsState build() => OfflineAsrSettingsState(
    backend: AsrBackend.offline,
    selectedModel: _model(_base),
    recommendedModel: _model(_base),
  );
}

/// 由测试决定「保存真正落地」的存储替身，用来复现旧回调晚到的顺序。
///
/// 每个保存槽位预先建好 [started] / [finish]，测试可以先等「保存已开始」，
/// 再决定它何时完成，不需要任意延时。
class _DelayedSpeechConfigStore extends SpeechConfigStore {
  final started = [Completer<void>(), Completer<void>()];
  final finish = [Completer<void>(), Completer<void>()];
  SpeechConfig? stored;
  int _calls = 0;

  @override
  Future<void> save(SpeechConfig config, {String? apiKey}) async {
    final index = _calls++;
    started[index].complete();
    await finish[index].future;
    stored = config;
  }

  @override
  Future<SpeechConfig?> read() async => stored;

  @override
  Future<String?> readApiKey() async => _sentinelSpeechKey;

  @override
  Future<String?> readCredentialVersion() async => 'delayed-version';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> secrets;
  late SharedPreferences preferences;
  late SpeechConfigStore speechStore;
  late ProviderConfigStore textStore;

  SpeechConfig openRouter() => const SpeechConfig(
    kind: SpeechProviderKind.openrouter,
    baseUrl: 'https://openrouter.ai/api/v1',
  );

  /// 两个独立的安全存储替身：语音与文字各用一份槽位。
  ProviderConfigStore buildTextStore() {
    final secureStorage = _MockSecureStorage();
    when(() => secureStorage.read(key: any(named: 'key'))).thenAnswer(
      (invocation) async => secrets['text:${_secureKeyName(invocation)}'],
    );
    when(
      () => secureStorage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((invocation) async {
      final value = invocation.namedArguments[#value];
      if (value is String) {
        secrets['text:${_secureKeyName(invocation)}'] = value;
      }
    });
    when(() => secureStorage.delete(key: any(named: 'key'))).thenAnswer((
      invocation,
    ) async {
      secrets.remove('text:${_secureKeyName(invocation)}');
    });
    return ProviderConfigStore(secureStorage: secureStorage);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secrets = {};
    preferences = await SharedPreferences.getInstance();
    final secureStorage = _MockSecureStorage();
    when(
      () => secureStorage.read(key: any(named: 'key')),
    ).thenAnswer((invocation) async => secrets[_secureKeyName(invocation)]);
    when(
      () => secureStorage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((invocation) async {
      final value = invocation.namedArguments[#value];
      if (value is String) {
        secrets[_secureKeyName(invocation)] = value;
      }
    });
    when(() => secureStorage.delete(key: any(named: 'key'))).thenAnswer((
      invocation,
    ) async {
      secrets.remove(_secureKeyName(invocation));
    });
    speechStore = SpeechConfigStore(
      secureStorage: secureStorage,
      preferences: () async => preferences,
    );
    textStore = buildTextStore();
  });

  ProviderContainer buildContainer({SpeechConfigStore? store}) {
    return ProviderContainer(
      overrides: [
        speechConfigStoreProvider.overrideWithValue(store ?? speechStore),
        providerConfigStoreProvider.overrideWithValue(textStore),
        sharedPreferencesProvider.overrideWithValue(preferences),
        recommendedAsrModelProvider.overrideWithValue(_model(_base)),
        systemRecognitionPlatformProvider.overrideWithValue(true),
        offlineAsrSettingsProvider.overrideWith(_FakeOfflineAsrNotifier.new),
      ],
    );
  }

  /// 每次保存都等待异步完成，避免用例之间互相污染。
  Future<SpeechConfigurationState> save(
    ProviderContainer container,
    SpeechConfig config, {
    String? apiKey,
  }) async {
    await container
        .read(speechConfigurationProvider.notifier)
        .save(config, apiKey: apiKey);
    return container.read(speechConfigurationProvider.future);
  }

  group('配置状态', () {
    test('保存后配置与凭据身份可读', () async {
      final container = buildContainer();
      addTearDown(container.dispose);

      final state = await save(
        container,
        openRouter().withOnlineModel(
          RecognitionPurpose.subtitle,
          'openai/whisper-large-v3',
        ),
        apiKey: _sentinelSpeechKey,
      );

      expect(state.config?.kind, SpeechProviderKind.openrouter);
      expect(
        state.config?.onlineModelFor(RecognitionPurpose.subtitle),
        'openai/whisper-large-v3',
      );
      expect(state.hasApiKey, isTrue);
      expect(state.isConfigured, isTrue);
      expect(state.credentialVersion, isNotNull);
    });

    test('缺 Key 时在线配置不可用，本机识别选择保持不变', () async {
      final container = buildContainer();
      addTearDown(container.dispose);

      final state = await save(container, openRouter());

      expect(state.config, isNotNull);
      expect(state.hasApiKey, isFalse);
      expect(state.isConfigured, isFalse);
      final settings = container.read(recognitionSettingsProvider);
      for (final purpose in RecognitionPurpose.values) {
        expect(settings.forPurpose(purpose).usesLocalModel, isTrue);
      }
    });

    test('重启时从存储读取上次保存的配置', () async {
      final first = buildContainer();
      await save(first, openRouter(), apiKey: _sentinelSpeechKey);
      first.dispose();

      final restarted = buildContainer();
      addTearDown(restarted.dispose);
      final state = await restarted.read(speechConfigurationProvider.future);

      expect(state.config?.baseUrl, 'https://openrouter.ai/api/v1');
      expect(state.hasApiKey, isTrue);
    });

    test('清除 Key 后回到未配置，配置本身仍可编辑', () async {
      final container = buildContainer();
      addTearDown(container.dispose);
      await save(container, openRouter(), apiKey: _sentinelSpeechKey);

      await container.read(speechConfigurationProvider.notifier).clearKey();
      final state = await container.read(speechConfigurationProvider.future);

      expect(state.config, isNotNull);
      expect(state.hasApiKey, isFalse);
      expect(state.isConfigured, isFalse);
    });
  });

  group('语音与文字 AI 分槽', () {
    test('保存语音配置不影响文字 AI 配置与 Key', () async {
      final container = buildContainer();
      addTearDown(container.dispose);

      await save(container, openRouter(), apiKey: _sentinelSpeechKey);

      expect(await textStore.read(), isNull);
      expect(await textStore.readApiKey(), isNull);
    });

    test('保存文字 AI 配置不影响语音配置与 Key', () async {
      final container = buildContainer();
      addTearDown(container.dispose);
      await save(container, openRouter(), apiKey: _sentinelSpeechKey);

      // 文字 AI 的运行时需要数据库，这里只验证两个存储槽互不覆盖。
      await textStore.save(
        const ProviderConfig(
          kind: ProviderKind.deepseek,
          baseUrl: 'https://api.deepseek.com',
          model: 'deepseek-flash',
        ),
        apiKey: _sentinelTextKey,
      );

      final state = await container.read(speechConfigurationProvider.future);
      expect(state.config?.baseUrl, 'https://openrouter.ai/api/v1');
      expect(state.hasApiKey, isTrue);
      expect(await speechStore.readApiKey(), _sentinelSpeechKey);
      expect(await textStore.readApiKey(), _sentinelTextKey);
    });
  });

  group('保存顺序', () {
    test('并发保存最终以后一次为准', () async {
      final container = buildContainer();
      addTearDown(container.dispose);
      final notifier = container.read(speechConfigurationProvider.notifier);

      final first = notifier.save(openRouter(), apiKey: _sentinelSpeechKey);
      final second = notifier.save(
        const SpeechConfig(
          kind: SpeechProviderKind.custom,
          baseUrl: 'https://speech.example.com/stt',
        ),
      );
      await Future.wait([first, second]);

      final state = await container.read(speechConfigurationProvider.future);
      expect(state.config?.baseUrl, 'https://speech.example.com/stt');
      expect(state.hasApiKey, isFalse);
    });

    test('晚到的旧保存回调不覆盖新配置', () async {
      final delayed = _DelayedSpeechConfigStore();
      final container = buildContainer(store: delayed);
      addTearDown(container.dispose);
      final notifier = container.read(speechConfigurationProvider.notifier);
      const newer = SpeechConfig(
        kind: SpeechProviderKind.custom,
        baseUrl: 'https://new.example.com/stt',
      );

      final firstSave = notifier.save(openRouter());
      await delayed.started[0].future;
      final secondSave = notifier.save(newer);
      await delayed.started[1].future;

      delayed.finish[1].complete();
      await secondSave;
      expect(
        (await container.read(
          speechConfigurationProvider.future,
        )).config?.baseUrl,
        'https://new.example.com/stt',
      );
      // 旧保存此时才落地，状态必须仍是最新配置。
      delayed.finish[0].complete();
      await firstSave;

      final state = await container.read(speechConfigurationProvider.future);
      expect(state.config?.baseUrl, 'https://new.example.com/stt');
    });

    test('较早的保存失败不覆盖后一次成功', () async {
      final delayed = _DelayedSpeechConfigStore();
      final container = buildContainer(store: delayed);
      addTearDown(container.dispose);
      final notifier = container.read(speechConfigurationProvider.notifier);
      const newer = SpeechConfig(
        kind: SpeechProviderKind.custom,
        baseUrl: 'https://new.example.com/stt',
      );

      final firstSave = notifier.save(openRouter());
      await delayed.started[0].future;
      final secondSave = notifier.save(newer);
      await delayed.started[1].future;

      delayed.finish[1].complete();
      await secondSave;
      delayed.finish[0].completeError(StateError('安全存储不可用'));
      await expectLater(firstSave, throwsStateError);

      final state = await container.read(speechConfigurationProvider.future);
      expect(state.config?.baseUrl, 'https://new.example.com/stt');
    });

    test('保存失败明确报错，不产生已保存状态', () async {
      final container = buildContainer();
      addTearDown(container.dispose);

      await expectLater(
        container
            .read(speechConfigurationProvider.notifier)
            .save(
              const SpeechConfig(
                kind: SpeechProviderKind.custom,
                baseUrl: 'file:///tmp',
              ),
            ),
        throwsArgumentError,
      );

      final state = await container.read(speechConfigurationProvider.future);
      expect(state.config, isNull);
      expect(state.hasApiKey, isFalse);
      expect(state.isConfigured, isFalse);
    });
  });
}
