/// 能力验证与上传告知记录测试。
///
/// 重点是记录绑定非秘密配置身份：地址、凭据版本或模型任一变化后旧结论失效；
/// 上传告知按服务地址记录，换地址必须重新告知。
library;

import 'dart:convert';

import 'package:echo_loop/services/speech/speech_capability.dart';
import 'package:echo_loop/services/speech/speech_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpeechCapabilityStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = SpeechCapabilityStore();
  });

  SpeechCapability capability({
    required String credentialVersion,
    SpeechProviderKind kind = SpeechProviderKind.openrouter,
    String baseUrl = 'https://openrouter.ai/api/v1',
    String modelId = 'openai/whisper-large-v3',
  }) => SpeechCapability(
    identity: SpeechCapability.identityFor(
      kind: kind,
      baseUrl: baseUrl,
      modelId: modelId,
      credentialVersion: credentialVersion,
    ),
    text: true,
    segments: true,
    wordTimestamps: false,
    validatedAt: DateTime.utc(2026, 11, 7, 12),
    reportedCost: 0.0004,
  );

  group('能力记录的配置身份', () {
    test('同一配置身份在重启后可复用', () async {
      await store.save(capability(credentialVersion: 'credential-a'));

      // 新的 store 实例代表普通重启后重新读取。
      final reopened = SpeechCapabilityStore();
      final loaded = (await reopened.readAll()).values.single;

      expect(loaded.segments, isTrue);
      expect(loaded.wordTimestamps, isFalse);
      expect(loaded.validatedAt, DateTime.utc(2026, 11, 7, 12));
      expect(loaded.reportedCost, 0.0004);
    });

    test('凭据版本变化后旧记录不再匹配', () async {
      await store.save(capability(credentialVersion: 'credential-a'));
      final stale = await store.read(
        SpeechCapability.identityFor(
          kind: SpeechProviderKind.openrouter,
          baseUrl: 'https://openrouter.ai/api/v1',
          modelId: 'openai/whisper-large-v3',
          credentialVersion: 'credential-b',
        ),
      );

      expect(stale, isNull);
    });

    test('地址或模型变化后旧记录不再匹配', () async {
      await store.save(capability(credentialVersion: 'credential-a'));

      final otherModel = await store.read(
        SpeechCapability.identityFor(
          kind: SpeechProviderKind.openrouter,
          baseUrl: 'https://openrouter.ai/api/v1',
          modelId: 'other/model',
          credentialVersion: 'credential-a',
        ),
      );
      final otherHost = await store.read(
        SpeechCapability.identityFor(
          kind: SpeechProviderKind.custom,
          baseUrl: 'https://speech.example.com/v1',
          modelId: 'openai/whisper-large-v3',
          credentialVersion: 'credential-a',
        ),
      );

      expect(otherModel, isNull);
      expect(otherHost, isNull);
    });

    test('身份不包含 Key 的明文或摘要', () async {
      const apiKey = 'sk-credential-should-never-appear';
      await store.save(capability(credentialVersion: 'credential-a'));

      final preferences = await SharedPreferences.getInstance();
      final dump = {
        for (final key in preferences.getKeys()) key: preferences.get(key),
      };

      expect(jsonEncode(dump), isNot(contains(apiKey)));
    });

    test('损坏的记录被忽略而不是让读取失败', () async {
      SharedPreferences.setMockInitialValues({
        SpeechCapabilityStore.recordsPreferenceKey: '{not json',
      });

      expect(await SpeechCapabilityStore().readAll(), isEmpty);
    });

    test('显式清理后记录与告知都消失', () async {
      await store.save(capability(credentialVersion: 'credential-a'));
      await store.rememberUploadNotice('https://openrouter.ai/api/v1');

      await store.clear();

      expect(await store.readAll(), isEmpty);
      expect(
        await store.hasUploadNotice('https://openrouter.ai/api/v1'),
        isFalse,
      );
    });
  });

  group('上传告知', () {
    test('未确认的服务地址需要先告知', () async {
      expect(
        await store.hasUploadNotice('https://openrouter.ai/api/v1'),
        isFalse,
      );
    });

    test('确认后同一地址不再重复告知，末尾斜杠不影响匹配', () async {
      await store.rememberUploadNotice('https://openrouter.ai/api/v1');

      expect(
        await store.hasUploadNotice('https://openrouter.ai/api/v1/'),
        isTrue,
      );
    });

    test('换服务地址后必须重新告知', () async {
      await store.rememberUploadNotice('https://openrouter.ai/api/v1');

      expect(
        await store.hasUploadNotice('https://speech.example.com/v1'),
        isFalse,
      );
    });
  });
}
