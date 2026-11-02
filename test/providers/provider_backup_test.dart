/// 备份恢复与切库的供应商边界：凭据不跨恢复，缓存不持有已关闭数据库。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:echo_loop/database/app_database.dart';
import 'package:echo_loop/database/providers.dart';
import 'package:echo_loop/providers/backup_provider.dart';
import 'package:echo_loop/providers/provider_configuration_provider.dart';
import 'package:echo_loop/providers/settings_provider.dart';
import 'package:echo_loop/providers/audio_library_provider.dart';
import 'package:echo_loop/providers/collection_provider.dart';
import 'package:echo_loop/providers/learning_progress_provider.dart';
import 'package:echo_loop/providers/tag_provider.dart';
import 'package:echo_loop/services/backup/backup_service.dart';
import 'package:echo_loop/services/provider/provider_config.dart';
import 'package:echo_loop/services/provider/provider_config_store.dart';
import 'package:echo_loop/services/sentence_ai_api_client.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppDatabase database;
  late ProviderConfigStore store;
  late ProviderContainer container;
  late WidgetRef widgetRef;
  late String? secureKey;
  late PathProviderPlatform previousPaths;
  late FixtureAdapter adapter;
  var failMigration = false;
  var failKeyDelete = false;

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
    secureKey = null;
    failMigration = false;
    failKeyDelete = false;
    final secure = _Secure();
    when(
      () => secure.read(key: any(named: 'key')),
    ).thenAnswer((_) async => secureKey);
    when(() => secure.delete(key: any(named: 'key'))).thenAnswer((_) async {
      if (failKeyDelete) throw StateError('secure storage unavailable');
      secureKey = null;
    });
    when(
      () => secure.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((call) async {
      final value = call.namedArguments[#value];
      secureKey = value is String ? value : null;
    });
    store = ProviderConfigStore(secureStorage: secure);
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
      failKeyDelete = true;

      await expectLater(performImport(widgetRef, path), throwsStateError);

      expect((await store.read())?.baseUrl, _localConfig.baseUrl);
      expect(await store.readApiKey(), 'synthetic-restore-key');
      expect(container.read(providerConfigurationProvider).hasError, isTrue);
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
