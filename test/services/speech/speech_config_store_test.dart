/// 在线语音配置与凭据存储测试。
///
/// 重点不是「能存能读」，而是语音服务与文字 AI 分槽、三个用途的在线模型互不覆盖、
/// Key 只进安全存储、地址或服务类型变化清除旧 Key，以及凭据版本不携带 Key 材料。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:echo_loop/models/recognition_selection.dart';
import 'package:echo_loop/services/speech/speech_config.dart';
import 'package:echo_loop/services/speech/speech_config_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

/// 取 mock 调用里的安全存储 key，避免把未校验的 dynamic 直接当 key 使用。
String _secureKeyName(Invocation invocation) {
  final name = invocation.namedArguments[#key];
  if (name is! String) throw StateError('安全存储缺少 key 名称');
  return name;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sentinelKey = 'sk-speech-sentinel-4b7d';
  const openRouterBaseUrl = 'https://openrouter.ai/api/v1';

  late Map<String, String> secrets;
  late SpeechConfigStore store;

  SpeechConfig openRouter({
    Map<RecognitionPurpose, String> models = const {},
  }) => SpeechConfig(
    kind: SpeechProviderKind.openrouter,
    baseUrl: openRouterBaseUrl,
    onlineModels: models,
  );

  SpeechConfig custom(String baseUrl) =>
      SpeechConfig(kind: SpeechProviderKind.custom, baseUrl: baseUrl);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secrets = {};
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
    store = SpeechConfigStore(secureStorage: secureStorage);
  });

  /// 普通偏好的全部内容，用于断言 Key 与派生摘要都没有落在这里。
  Future<Map<String, Object?>> rawPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    return {for (final key in preferences.getKeys()) key: preferences.get(key)};
  }

  group('读取与保存', () {
    test('未保存时没有配置也没有凭据', () async {
      expect(await store.read(), isNull);
      expect(await store.readApiKey(), isNull);
      expect(await store.isConfigured(), isFalse);
      expect(await store.readCredentialVersion(), isNull);
    });

    test('保存后服务类型与根地址往返一致', () async {
      await store.save(openRouter());

      final restored = await store.read();
      expect(restored?.kind, SpeechProviderKind.openrouter);
      expect(restored?.baseUrl, openRouterBaseUrl);
    });

    test('三个用途的在线模型各自保存，互不覆盖', () async {
      await store.save(
        openRouter().withOnlineModel(
          RecognitionPurpose.subtitle,
          'openai/whisper-large-v3',
        ),
      );
      await store.save(
        (await store.read())!.withOnlineModel(
          RecognitionPurpose.retell,
          'openai/whisper-1',
        ),
      );

      final restored = await store.read();
      expect(
        restored?.onlineModelFor(RecognitionPurpose.subtitle),
        'openai/whisper-large-v3',
      );
      expect(
        restored?.onlineModelFor(RecognitionPurpose.retell),
        'openai/whisper-1',
      );
      expect(restored?.onlineModelFor(RecognitionPurpose.shadowing), isEmpty);
    });

    test('损坏的普通配置不会被当成可用配置', () async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        SpeechConfigStore.configPreferenceKey,
        'not-json',
      );

      expect(await store.read(), isNull);
    });
  });

  group('凭据隔离', () {
    test('Key 只进安全存储，普通偏好里没有明文或派生摘要', () async {
      await store.save(openRouter(), apiKey: sentinelKey);

      final digest = sha256.convert(utf8.encode(sentinelKey)).toString();
      final preferences = await rawPreferences();
      for (final entry in preferences.entries) {
        expect(
          '${entry.value}',
          isNot(contains(sentinelKey)),
          reason: entry.key,
        );
        expect('${entry.value}', isNot(contains(digest)), reason: entry.key);
      }
      expect(secrets.values, contains(sentinelKey));
    });

    test('clearKey 只删凭据，保留配置并让旧验证失效', () async {
      await store.save(openRouter(), apiKey: sentinelKey);
      final versionWithKey = await store.readCredentialVersion();

      await store.clearKey();

      expect(await store.readApiKey(), isNull);
      expect(await store.read(), isNotNull);
      expect(await store.readCredentialVersion(), isNot(versionWithKey));
    });

    test('传空 Key 等于删除凭据', () async {
      await store.save(openRouter(), apiKey: sentinelKey);
      await store.save(openRouter(), apiKey: '  ');

      expect(await store.readApiKey(), isNull);
    });

    test('保存失败时保留原配置与凭据', () async {
      await store.save(openRouter(), apiKey: sentinelKey);

      await expectLater(
        store.save(custom('file:///tmp'), apiKey: 'other'),
        throwsArgumentError,
      );

      expect((await store.read())?.baseUrl, openRouterBaseUrl);
      expect(await store.readApiKey(), sentinelKey);
    });
  });

  group('配置变化边界', () {
    test('换地址清除旧 Key，新地址不继承旧凭据', () async {
      await store.save(openRouter(), apiKey: sentinelKey);

      await store.save(custom('https://speech.example.com/proxy/stt'));

      expect(await store.readApiKey(), isNull);
      expect(await store.isConfigured(), isFalse);
    });

    test('换服务类型清除旧 Key', () async {
      await store.save(openRouter(), apiKey: sentinelKey);

      await store.save(custom(openRouterBaseUrl));

      expect(await store.readApiKey(), isNull);
    });

    test('只改在线模型保留 Key，凭据版本不变', () async {
      await store.save(openRouter(), apiKey: sentinelKey);
      final version = await store.readCredentialVersion();

      await store.save(
        (await store.read())!.withOnlineModel(
          RecognitionPurpose.shadowing,
          'openai/whisper-large-v3-turbo',
        ),
      );

      expect(await store.readApiKey(), sentinelKey);
      expect(await store.readCredentialVersion(), version);
    });

    test('重复保存相同地址与 Key 不使已验证状态失效', () async {
      await store.save(openRouter(), apiKey: sentinelKey);
      final version = await store.readCredentialVersion();

      await store.save(openRouter(), apiKey: sentinelKey);

      expect(await store.readCredentialVersion(), version);
    });

    test('并发保存按调用顺序落地，旧地址的 Key 不落到新地址', () async {
      final first = store.save(openRouter(), apiKey: sentinelKey);
      final second = store.save(custom('https://speech.example.com/stt'));

      await Future.wait([first, second]);

      expect((await store.read())?.baseUrl, 'https://speech.example.com/stt');
      expect(await store.readApiKey(), isNull);
    });
  });

  group('凭据版本', () {
    test('替换 Key 让绑定旧凭据的验证失效', () async {
      await store.save(openRouter(), apiKey: sentinelKey);
      final version = await store.readCredentialVersion();

      await store.save(openRouter(), apiKey: 'sk-speech-rotated-91cf');

      expect(await store.readCredentialVersion(), isNot(version));
    });

    test('恢复入口可以显式让旧验证失效', () async {
      await store.save(openRouter(), apiKey: sentinelKey);
      final version = await store.readCredentialVersion();

      await store.rotateCredentialVersion();

      expect(await store.readCredentialVersion(), isNot(version));
    });
  });

  group('根地址语义', () {
    test('直接追加 /audio/transcriptions，不自动补 /v1', () {
      expect(
        openRouter().transcriptionUrl,
        'https://openrouter.ai/api/v1/audio/transcriptions',
      );
      expect(
        custom('https://speech.example.com/stt').transcriptionUrl,
        'https://speech.example.com/stt/audio/transcriptions',
      );
    });

    test('尾部斜杠不产生重复分隔符', () {
      expect(
        custom('https://speech.example.com/stt/').transcriptionUrl,
        'https://speech.example.com/stt/audio/transcriptions',
      );
    });
  });

  group('配置解析', () {
    test('只读取已知用途的在线模型', () {
      final config = SpeechConfig.fromJson({
        'kind': 'custom',
        'baseUrl': 'https://speech.example.com',
        'models': {'subtitle': 'openai/whisper-1', 'unknown': 'ignored'},
      });

      expect(
        config?.onlineModelFor(RecognitionPurpose.subtitle),
        'openai/whisper-1',
      );
      expect(config?.onlineModels.keys, [RecognitionPurpose.subtitle]);
    });

    test('未知服务类型或非法地址不产生配置', () {
      expect(
        SpeechConfig.fromJson({
          'kind': 'unknown',
          'baseUrl': 'https://speech.example.com',
        }),
        isNull,
      );
      expect(
        SpeechConfig.fromJson({'kind': 'custom', 'baseUrl': 'file:///tmp'}),
        isNull,
      );
    });

    test('预设只给 OpenRouter 提供根地址', () {
      expect(
        SpeechProviderKind.openrouter.presetBaseUrl,
        'https://openrouter.ai/api/v1',
      );
      expect(SpeechProviderKind.custom.presetBaseUrl, isNull);
    });
  });
}
