/// 供应商配置与凭据存储测试
///
/// 重点不是「能存能读」，而是三条安全约束：Key 只进安全存储、Key 不进 `toString`、
/// Base URL 不接受非 http(s) 与内嵌账号密码。
library;

import 'package:echo_loop/services/provider/provider_config.dart';
import 'package:echo_loop/services/provider/provider_config_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sentinelKey = 'sk-test-sentinel-9f3a';

  late _MockSecureStorage secureStorage;
  late ProviderConfigStore store;
  late String? storedSecret;

  ProviderConfig deepSeek() => const ProviderConfig(
    kind: ProviderKind.deepseek,
    baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-flash',
    promptVersion: 'v1',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storedSecret = null;
    secureStorage = _MockSecureStorage();
    when(
      () => secureStorage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((invocation) async {
      final value = invocation.namedArguments[const Symbol('value')];
      storedSecret = value is String ? value : null;
    });
    when(
      () => secureStorage.read(key: any(named: 'key')),
    ).thenAnswer((_) async => storedSecret);
    when(() => secureStorage.delete(key: any(named: 'key'))).thenAnswer((
      _,
    ) async {
      storedSecret = null;
    });
    store = ProviderConfigStore(secureStorage: secureStorage);
  });

  group('读取与保存', () {
    test('未保存时 read 返回 null 且未配置', () async {
      expect(await store.read(), isNull);
      expect(await store.isConfigured(), isFalse);
    });

    test('保存后往返一致', () async {
      await store.save(deepSeek());

      final restored = await store.read();
      expect(restored, isNotNull);
      expect(restored?.kind, ProviderKind.deepseek);
      expect(restored?.baseUrl, 'https://api.deepseek.com');
      expect(restored?.model, 'deepseek-flash');
      expect(restored?.promptVersion, 'v1');
    });

    test('切换供应商会覆盖旧值', () async {
      await store.save(deepSeek());
      await store.save(
        const ProviderConfig(
          kind: ProviderKind.openrouter,
          baseUrl: 'https://openrouter.ai/api/v1',
          model: 'mistralai/mistral-nemo',
          promptVersion: 'v1',
        ),
      );

      final restored = await store.read();
      expect(restored?.kind, ProviderKind.openrouter);
      expect(restored?.baseUrl, 'https://openrouter.ai/api/v1');
    });
  });

  group('凭据隔离', () {
    test('Key 只进安全存储，不进普通偏好', () async {
      await store.save(deepSeek(), apiKey: sentinelKey);

      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expect('${prefs.get(key)}', isNot(contains(sentinelKey)));
      }
      expect(storedSecret, sentinelKey);
    });

    test('readApiKey 返回已保存的 Key', () async {
      await store.save(deepSeek(), apiKey: sentinelKey);

      expect(await store.readApiKey(), sentinelKey);
    });

    test('clearKey 删除 Key 但保留配置', () async {
      await store.save(deepSeek(), apiKey: sentinelKey);

      await store.clearKey();

      expect(await store.readApiKey(), isNull);
      expect(await store.read(), isNotNull);
    });

    test('传空 Key 等于删除', () async {
      await store.save(deepSeek(), apiKey: sentinelKey);
      await store.save(deepSeek(), apiKey: '');

      expect(await store.readApiKey(), isNull);
    });

    test('toString 不含 Key 材料', () async {
      await store.save(deepSeek(), apiKey: sentinelKey);
      final restored = await store.read();

      expect(restored.toString(), isNot(contains(sentinelKey)));
    });
  });

  group('配置边界', () {
    test('切换主机时清除旧 Key，避免泄漏给新端点', () async {
      await store.save(deepSeek(), apiKey: sentinelKey);
      await store.save(
        const ProviderConfig(
          kind: ProviderKind.custom,
          baseUrl: 'https://example.com/v1',
          model: 'example',
        ),
      );
      expect(await store.readApiKey(), isNull);
      expect(await store.isConfigured(), isFalse);
    });

    test('保存非法地址前拒绝，不改写配置或凭据', () async {
      await store.save(deepSeek(), apiKey: sentinelKey);
      await expectLater(
        store.save(
          const ProviderConfig(
            kind: ProviderKind.custom,
            baseUrl: 'file:///tmp',
            model: 'example',
          ),
        ),
        throwsArgumentError,
      );
      expect((await store.read())?.baseUrl, 'https://api.deepseek.com');
      expect(await store.readApiKey(), sentinelKey);
    });
  });

  group('是否已配置', () {
    test('只有配置没有 Key 时不算已配置', () async {
      await store.save(deepSeek());

      expect(await store.isConfigured(), isFalse);
    });

    test('配置与 Key 齐备时算已配置', () async {
      await store.save(deepSeek(), apiKey: sentinelKey);

      expect(await store.isConfigured(), isTrue);
    });
  });

  group('Base URL 校验', () {
    test('合法的 https 地址通过', () {
      expect(baseUrlError('https://api.deepseek.com'), isNull);
      expect(baseUrlError('https://openrouter.ai/api/v1'), isNull);
      expect(baseUrlError('http://127.0.0.1:8080/v1'), isNull);
    });

    test('非 http(s) 协议被拒', () {
      expect(baseUrlError('ftp://example.com'), isNotNull);
      expect(baseUrlError('api.deepseek.com'), isNotNull);
    });

    test('内嵌账号密码被拒', () {
      expect(baseUrlError('https://user@example.com'), isNotNull);
    });

    test('空值与无主机被拒', () {
      expect(baseUrlError(''), isNotNull);
      expect(baseUrlError('   '), isNotNull);
      expect(baseUrlError('https://'), isNotNull);
    });
  });

  group('预设', () {
    test('DeepSeek 与 OpenRouter 有预设地址与模型', () {
      expect(ProviderKind.deepseek.presetBaseUrl, 'https://api.deepseek.com');
      expect(ProviderKind.deepseek.presetModel, isNotNull);
      expect(
        ProviderKind.openrouter.presetBaseUrl,
        'https://openrouter.ai/api/v1',
      );
      expect(ProviderKind.openrouter.presetModel, isNotNull);
    });

    test('自定义没有预设，需用户填写', () {
      expect(ProviderKind.custom.presetBaseUrl, isNull);
      expect(ProviderKind.custom.presetModel, isNull);
    });
  });
}
