/// 供应商配置生命周期测试
///
/// 只验证「配置 → 可用运行时」这条接缝：未配置不产生运行时、保存后携带正确身份、
/// 换地址时旧凭据不得继续被使用（spec REQ-1、REQ-2、REQ-11）。
library;

import 'package:dio/dio.dart';
import 'package:echo_loop/database/daos/sentence_ai_cache_dao.dart';
import 'package:echo_loop/database/providers.dart';
import 'package:echo_loop/providers/provider_configuration_provider.dart';
import 'package:echo_loop/services/provider/provider_config.dart';
import 'package:echo_loop/services/provider/provider_config_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SecureStorage extends Mock implements FlutterSecureStorage {}

class _CacheDao extends Mock implements SentenceAiCacheDao {}

const _deepSeek = ProviderConfig(
  kind: ProviderKind.deepseek,
  baseUrl: 'https://api.deepseek.com',
  model: 'deepseek-flash',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late _SecureStorage secure;
  late String? storedKey;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storedKey = null;
    secure = _SecureStorage();
    when(
      () => secure.read(key: any(named: 'key')),
    ).thenAnswer((_) async => storedKey);
    when(
      () => secure.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((invocation) async {
      final value = invocation.namedArguments[#value];
      storedKey = value is String ? value : null;
    });
    when(() => secure.delete(key: any(named: 'key'))).thenAnswer((_) async {
      storedKey = null;
    });

    final dao = _CacheDao();
    when(() => dao.getByHash(any(), any())).thenAnswer((_) async => null);
    when(() => dao.upsert(any(), any(), any())).thenAnswer((_) async {});

    container = ProviderContainer(
      overrides: [
        providerConfigStoreProvider.overrideWithValue(
          ProviderConfigStore(secureStorage: secure),
        ),
        providerDioFactoryProvider.overrideWithValue(Dio.new),
        sentenceAiCacheDaoProvider.overrideWithValue(dao),
      ],
    );
  });

  tearDown(() => container.dispose());

  Future<ProviderRuntime?> runtime() =>
      container.read(providerConfigurationProvider.future);

  test('未配置时不产生运行时，也不会持有 Key', () async {
    expect(await runtime(), isNull);
    expect(storedKey, isNull);
  });

  test('保存配置后运行时携带该配置与 Key', () async {
    await container
        .read(providerConfigurationProvider.notifier)
        .save(_deepSeek, apiKey: 'fixture-key');

    final value = await runtime();
    expect(value, isNotNull);
    expect(value?.config.baseUrl, 'https://api.deepseek.com');
    expect(value?.config.model, 'deepseek-flash');
    expect(value?.apiKey, 'fixture-key');
  });

  test('只保存配置不传 Key 时保留原有 Key', () async {
    final notifier = container.read(providerConfigurationProvider.notifier);
    await notifier.save(_deepSeek, apiKey: 'fixture-key');
    await notifier.save(
      const ProviderConfig(
        kind: ProviderKind.deepseek,
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-reasoner',
      ),
    );

    final value = await runtime();
    expect(value?.config.model, 'deepseek-reasoner');
    expect(value?.apiKey, 'fixture-key');
  });

  test('换 Base URL 且未提供新 Key 时回到未配置，旧 Key 不被复用', () async {
    final notifier = container.read(providerConfigurationProvider.notifier);
    await notifier.save(_deepSeek, apiKey: 'fixture-key');

    await notifier.save(
      const ProviderConfig(
        kind: ProviderKind.custom,
        baseUrl: 'https://my-gateway.example/v1',
        model: 'some-model',
      ),
    );

    expect(await runtime(), isNull);
    expect(storedKey, isNull);
  });

  test('删除 Key 后回到未配置', () async {
    final notifier = container.read(providerConfigurationProvider.notifier);
    await notifier.save(_deepSeek, apiKey: 'fixture-key');
    await notifier.clearKey();

    expect(await runtime(), isNull);
    expect(storedKey, isNull);
  });
}
