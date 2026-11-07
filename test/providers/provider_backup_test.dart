/// 备份恢复与切库的供应商边界：凭据不跨恢复，缓存不持有已关闭数据库。
///
/// 在线语音配置与文字 AI 分槽：普通语音配置参与备份，两份 Key 都不参与；
/// 恢复前停用并清除两份 Key，失败回滚原配置与凭据，成功后要求重填并重验。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:echo_loop/database/app_database.dart';
import 'package:echo_loop/database/providers.dart';
import 'package:echo_loop/models/recognition_selection.dart';
import 'package:echo_loop/providers/backup_provider.dart';
import 'package:echo_loop/providers/provider_configuration_provider.dart';
import 'package:echo_loop/providers/recognition_settings_provider.dart';
import 'package:echo_loop/providers/speech_configuration_provider.dart';
import 'package:echo_loop/providers/settings_provider.dart';
import 'package:echo_loop/providers/audio_library_provider.dart';
import 'package:echo_loop/providers/collection_provider.dart';
import 'package:echo_loop/providers/learning_progress_provider.dart';
import 'package:echo_loop/providers/tag_provider.dart';
import 'package:echo_loop/services/backup/backup_service.dart';
import 'package:echo_loop/services/provider/provider_config.dart';
import 'package:echo_loop/services/provider/provider_config_store.dart';
import 'package:echo_loop/services/sentence_ai_api_client.dart';
import 'package:echo_loop/services/speech/speech_capability.dart';
import 'package:echo_loop/services/speech/speech_config.dart';
import 'package:echo_loop/services/speech/speech_config_store.dart';
import 'package:echo_loop/utils/app_data_dir.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mock_providers.dart';
import '../helpers/provider_fixture.dart' show FixtureAdapter;

class _Secure extends Mock implements FlutterSecureStorage {}

/// 一份安全存储替身的内容；语音与文字 AI 各用一份，验证两边互不共享。
class _Secrets {
  final values = <String, String>{};
  bool failDelete = false;
}

String _secureKeyName(Invocation invocation) {
  final name = invocation.namedArguments[#key];
  if (name is! String) throw StateError('安全存储缺少 key 名称');
  return name;
}

_Secure _mockSecure(_Secrets secrets) {
  final secure = _Secure();
  when(() => secure.read(key: any(named: 'key'))).thenAnswer(
    (invocation) async => secrets.values[_secureKeyName(invocation)],
  );
  when(
    () => secure.write(
      key: any(named: 'key'),
      value: any(named: 'value'),
    ),
  ).thenAnswer((invocation) async {
    final value = invocation.namedArguments[#value];
    if (value is String) {
      secrets.values[_secureKeyName(invocation)] = value;
    }
  });
  when(() => secure.delete(key: any(named: 'key'))).thenAnswer((
    invocation,
  ) async {
    if (secrets.failDelete) throw StateError('secure storage unavailable');
    secrets.values.remove(_secureKeyName(invocation));
  });
  return secure;
}

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

const _localConfig = ProviderConfig(
  kind: ProviderKind.custom,
  baseUrl: 'https://local-provider.example/v1',
  model: 'model',
);
const _restoredConfig = ProviderConfig(
  kind: ProviderKind.custom,
  baseUrl: 'https://restored-provider.example/v1',
  model: 'model',
);
const _localSpeechConfig = SpeechConfig(
  kind: SpeechProviderKind.custom,
  baseUrl: 'https://local-speech.example/stt',
  onlineModels: {RecognitionPurpose.subtitle: 'local/whisper-large-v3'},
);
const _restoredSpeechConfig = SpeechConfig(
  kind: SpeechProviderKind.custom,
  baseUrl: 'https://restored-speech.example/stt',
  onlineModels: {
    RecognitionPurpose.subtitle: 'openai/whisper-large-v3',
    RecognitionPurpose.retell: 'openai/whisper-1',
  },
);

/// 读取备份 ZIP 里的普通偏好，验证进入备份的实际内容。
Future<Map<String, Object?>> _backupSettings(String path) async {
  final input = InputFileStream(path);
  final archive = ZipDecoder().decodeStream(input);
  try {
    final entry = archive.findFile('settings.json');
    if (entry == null) throw StateError('备份缺少 settings.json');
    final decoded = jsonDecode(utf8.decode(entry.content));
    if (decoded is! Map<Object?, Object?>) {
      throw StateError('settings.json 不是 JSON 对象');
    }
    return {for (final item in decoded.entries) '${item.key}': item.value};
  } finally {
    archive.clearSync();
    input.closeSync();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppDatabase database;
  late ProviderConfigStore store;
  late SpeechConfigStore speechStore;
  late _Secrets textSecrets;
  late _Secrets speechSecrets;
  late ProviderContainer container;
  late WidgetRef widgetRef;
  late PathProviderPlatform previousPaths;
  late FixtureAdapter adapter;
  var failMigration = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('provider_restore_');
    appDataDirectoryOverride = root;
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    database = AppDatabase(
      NativeDatabase(File(p.join(root.path, 'echo_loop.db'))),
    );
    await database.customSelect('SELECT 1').get();
    initAppDatabase(database);
    failMigration = false;
    textSecrets = _Secrets();
    speechSecrets = _Secrets();
    store = ProviderConfigStore(secureStorage: _mockSecure(textSecrets));
    speechStore = SpeechConfigStore(secureStorage: _mockSecure(speechSecrets));
    adapter = FixtureAdapter();
  });

  tearDown(() async {
    final currentDatabase = container.read(appDatabaseProvider);
    container.dispose();
    await currentDatabase.close();
    await database.close();
    await adapter.arrived.close();
    appDataDirectoryOverride = null;
    PathProviderPlatform.instance = previousPaths;
    await root.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    container = ProviderContainer(
      overrides: [
        backupServiceProvider.overrideWithValue(
          BackupService(
            database,
            restoredAppUpdateMigrator: (preferences, version) async {
              if (failMigration) throw StateError('migration failed');
            },
          ),
        ),
        providerConfigStoreProvider.overrideWithValue(store),
        speechConfigStoreProvider.overrideWithValue(speechStore),
        providerDioFactoryProvider.overrideWithValue(
          () => Dio()..httpClientAdapter = adapter,
        ),
        appSettingsProvider.overrideWith(TestAppSettings.new),
        audioLibraryProvider.overrideWith(TestAudioLibrary.new),
        collectionListProvider.overrideWith(TestCollectionList.new),
        learningProgressNotifierProvider.overrideWith(
          TestLearningProgressNotifier.new,
        ),
        tagListProvider.overrideWith(TestTagList.new),
        dictionaryOverride(),
        ...studyTimeOverrides(),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              widgetRef = ref;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
  }

  Future<String> backup() async => BackupService(
    database,
  ).exportData(outputDir: root.path, appVersion: 'test', platform: 'android');

  for (final config in [_localConfig, _restoredConfig]) {
    testWidgets('恢复 ${config.baseUrl} 后 Key 必须重填，不复用本机凭据', (tester) async {
      await pump(tester);
      await tester.runAsync(() async {
        await store.save(config);
        final path = await backup();
        await container
            .read(providerConfigurationProvider.notifier)
            .save(_localConfig, apiKey: 'synthetic-restore-key');
        final oldRuntime = await container.read(
          providerConfigurationProvider.future,
        );
        expect(oldRuntime, isNotNull);

        await performImport(widgetRef, path);

        expect((await store.read())?.baseUrl, config.baseUrl);
        expect(await store.readApiKey(), isNull);
        expect(
          await container.read(providerConfigurationProvider.future),
          isNull,
        );
        expect(adapter.requests, isEmpty);
      });
    });
  }

  testWidgets('恢复失败回滚后保留原配置和 Key，重建可用的缓存客户端', (tester) async {
    await pump(tester);
    await tester.runAsync(() async {
      await store.save(_restoredConfig);
      final path = await backup();
      await container
          .read(providerConfigurationProvider.notifier)
          .save(_localConfig, apiKey: 'synthetic-restore-key');
      final oldRuntime = await container.read(
        providerConfigurationProvider.future,
      );
      failMigration = true;
      await expectLater(performImport(widgetRef, path), throwsStateError);

      expect((await store.read())?.baseUrl, _localConfig.baseUrl);
      expect(await store.readApiKey(), 'synthetic-restore-key');
      final runtime = await container.read(
        providerConfigurationProvider.future,
      );
      expect(runtime, isNot(same(oldRuntime)));
      adapter.completion({'translation': 'restored local data'});
      final frame = await container
          .read(sentenceAiApiClientProvider)
          .translateStream('After rollback')
          .last;
      expect(frame.translation.translation, 'restored local data');
    });
  });

  testWidgets('Key 清除失败时中止恢复，保留原地址和可读数据库', (tester) async {
    await pump(tester);
    await tester.runAsync(() async {
      await store.save(_restoredConfig);
      final path = await backup();
      await container
          .read(providerConfigurationProvider.notifier)
          .save(_localConfig, apiKey: 'synthetic-restore-key');
      textSecrets.failDelete = true;

      await expectLater(performImport(widgetRef, path), throwsStateError);

      expect((await store.read())?.baseUrl, _localConfig.baseUrl);
      expect(await store.readApiKey(), 'synthetic-restore-key');
      expect(container.read(providerConfigurationProvider).hasError, isTrue);
      expect(await database.customSelect('SELECT 1').get(), hasLength(1));
    });
  });

  testWidgets('备份包含语音普通配置与用途选择，不含两份 Key', (tester) async {
    await pump(tester);
    await tester.runAsync(() async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        retellModePrefsKey,
        RecognitionMode.system.name,
      );
      await store.save(_localConfig, apiKey: 'synthetic-text-key');
      await speechStore.save(
        _localSpeechConfig,
        apiKey: 'synthetic-speech-key',
      );
      final path = await backup();

      final settings = await _backupSettings(path);
      expect(settings[retellModePrefsKey], RecognitionMode.system.name);
      final speechConfig = '${settings[SpeechConfigStore.configPreferenceKey]}';
      expect(speechConfig, contains(_localSpeechConfig.baseUrl));
      expect(speechConfig, contains('local/whisper-large-v3'));
      final all = settings.toString();
      expect(all, isNot(contains('synthetic-text-key')));
      expect(all, isNot(contains('synthetic-speech-key')));
      final backupText = utf8.decode(
        await File(path).readAsBytes(),
        allowMalformed: true,
      );
      expect(backupText, isNot(contains('synthetic-speech-key')));
      expect(backupText, isNot(contains('synthetic-text-key')));
    });
  });

  testWidgets('恢复成功后语音 Key 与文字 Key 都必须重填，配置取自备份', (tester) async {
    await pump(tester);
    await tester.runAsync(() async {
      await store.save(_restoredConfig);
      await speechStore.save(
        _restoredSpeechConfig,
        apiKey: 'backup-speech-key',
      );
      final path = await backup();
      final backupCredentialVersion = await speechStore.readCredentialVersion();

      await container
          .read(providerConfigurationProvider.notifier)
          .save(_localConfig, apiKey: 'synthetic-text-key');
      await speechStore.save(
        _localSpeechConfig,
        apiKey: 'synthetic-speech-key',
      );
      // 本机现有配置已产生自己的凭据版本，恢复必须让它失效。
      final localCredentialVersion = await speechStore.readCredentialVersion();
      expect(
        await container.read(speechConfigurationProvider.future),
        isNotNull,
      );

      await performImport(widgetRef, path);

      expect((await store.read())?.baseUrl, _restoredConfig.baseUrl);
      expect(await store.readApiKey(), isNull);
      expect(
        (await speechStore.read())?.baseUrl,
        _restoredSpeechConfig.baseUrl,
      );
      expect(
        (await speechStore.read())?.onlineModelFor(RecognitionPurpose.retell),
        'openai/whisper-1',
      );
      expect(await speechStore.readApiKey(), isNull);

      final state = await container.read(speechConfigurationProvider.future);
      expect(state.config?.baseUrl, _restoredSpeechConfig.baseUrl);
      expect(state.hasApiKey, isFalse);
      expect(state.isConfigured, isFalse);
      expect(state.credentialVersion, isNot(backupCredentialVersion));
      expect(state.credentialVersion, isNot(localCredentialVersion));
      // 恢复不自动测试、不上传。
      expect(adapter.requests, isEmpty);
    });
  });

  testWidgets('能力验证与上传告知不进入备份，恢复后显式失效', (tester) async {
    await pump(tester);
    await tester.runAsync(() async {
      await speechStore.save(
        _localSpeechConfig,
        apiKey: 'synthetic-speech-key',
      );
      final capabilityStore = SpeechCapabilityStore();
      await capabilityStore.save(
        SpeechCapability(
          identity: SpeechCapability.identityFor(
            kind: _localSpeechConfig.kind,
            baseUrl: _localSpeechConfig.baseUrl,
            modelId: 'local/whisper-large-v3',
            credentialVersion: await speechStore.readCredentialVersion(),
          ),
          text: true,
          segments: true,
          wordTimestamps: false,
          validatedAt: DateTime.utc(2026, 11, 7, 12),
        ),
      );
      await capabilityStore.rememberUploadNotice(_localSpeechConfig.baseUrl);

      final path = await backup();
      final settings = await _backupSettings(path);
      expect(
        settings.keys.where(
          (key) => key.startsWith(SpeechCapabilityStore.preferencePrefix),
        ),
        isEmpty,
      );

      // 黑名单只会保留本机旧值，恢复必须显式清理，否则旧验证会描述新配置。
      await performImport(widgetRef, path);

      expect(await capabilityStore.readAll(), isEmpty);
      expect(
        await capabilityStore.hasUploadNotice(_localSpeechConfig.baseUrl),
        isFalse,
      );
    });
  });

  testWidgets('恢复失败回滚语音配置与两份凭据', (tester) async {
    await pump(tester);
    await tester.runAsync(() async {
      await store.save(_restoredConfig);
      await speechStore.save(
        _restoredSpeechConfig,
        apiKey: 'backup-speech-key',
      );
      final path = await backup();
      await container
          .read(providerConfigurationProvider.notifier)
          .save(_localConfig, apiKey: 'synthetic-text-key');
      await speechStore.save(
        _localSpeechConfig,
        apiKey: 'synthetic-speech-key',
      );

      failMigration = true;
      await expectLater(performImport(widgetRef, path), throwsStateError);

      expect((await store.read())?.baseUrl, _localConfig.baseUrl);
      expect(await store.readApiKey(), 'synthetic-text-key');
      expect((await speechStore.read())?.baseUrl, _localSpeechConfig.baseUrl);
      expect(await speechStore.readApiKey(), 'synthetic-speech-key');
      final state = await container.read(speechConfigurationProvider.future);
      expect(state.config?.baseUrl, _localSpeechConfig.baseUrl);
      expect(state.hasApiKey, isTrue);
      expect(container.read(speechConfigurationProvider).hasError, isFalse);
    });
  });

  testWidgets('语音 Key 清除失败时中止恢复，保留原语音配置与 Key', (tester) async {
    await pump(tester);
    await tester.runAsync(() async {
      await store.save(_restoredConfig);
      await speechStore.save(
        _restoredSpeechConfig,
        apiKey: 'backup-speech-key',
      );
      final path = await backup();
      await container
          .read(providerConfigurationProvider.notifier)
          .save(_localConfig, apiKey: 'synthetic-text-key');
      await speechStore.save(
        _localSpeechConfig,
        apiKey: 'synthetic-speech-key',
      );
      speechSecrets.failDelete = true;

      await expectLater(performImport(widgetRef, path), throwsStateError);

      // 不能继续使用地址与 Key 错配的客户端：恢复中止，本机仍是配套的配置与 Key。
      expect((await speechStore.read())?.baseUrl, _localSpeechConfig.baseUrl);
      expect(await speechStore.readApiKey(), 'synthetic-speech-key');
      final state = await container.read(speechConfigurationProvider.future);
      expect(state.config?.baseUrl, _localSpeechConfig.baseUrl);
      expect(state.hasApiKey, isTrue);
      expect(await store.readApiKey(), 'synthetic-text-key');
      expect(await database.customSelect('SELECT 1').get(), hasLength(1));
    });
  });

  testWidgets('切库后供应商缓存绑定新 DAO，不再访问关闭的数据库', (tester) async {
    await pump(tester);
    await tester.runAsync(() async {
      await container
          .read(providerConfigurationProvider.notifier)
          .save(_localConfig, apiKey: 'synthetic-switch-key');
      final oldRuntime = await container.read(
        providerConfigurationProvider.future,
      );
      adapter.completion({'translation': 'old'});
      await container
          .read(sentenceAiApiClientProvider)
          .translateStream('Hello')
          .last;
      final nextDatabase = AppDatabase(NativeDatabase.memory());
      await closeCurrentDatabase();
      switchAppDatabase(nextDatabase, widgetRef);
      final nextRuntime = await container.read(
        providerConfigurationProvider.future,
      );
      expect(nextRuntime, isNot(same(oldRuntime)));
      adapter.completion({'translation': 'new'});
      final frame = await container
          .read(sentenceAiApiClientProvider)
          .translateStream('Hello')
          .last;
      expect(frame.translation.translation, 'new');
      expect(adapter.requests, hasLength(2));
    });
  });
}
