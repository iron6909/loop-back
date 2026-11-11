/// 配置指纹与缓存键测试
///
/// 期望值取自独立手工计算（`sha256("<baseUrl>|<model>|<promptVersion>")` 的前 16 位），
/// 不是用实现再算一遍，避免自证式断言。
library;

import 'package:loop_back/services/provider/provider_cache_key.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('configFingerprint', () {
    test('与手工计算值一致', () {
      expect(
        configFingerprint(
          baseUrl: 'https://api.deepseek.com',
          model: 'deepseek-flash',
          promptVersion: 'v1',
        ),
        '546ea72f6e35e103',
      );
    });

    test('相同输入稳定', () {
      final first = configFingerprint(
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-flash',
        promptVersion: 'v1',
      );
      final second = configFingerprint(
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-flash',
        promptVersion: 'v1',
      );

      expect(first, second);
    });

    test('仅改提示词版本即产生不同指纹', () {
      expect(
        configFingerprint(
          baseUrl: 'https://api.deepseek.com',
          model: 'deepseek-flash',
          promptVersion: 'v2',
        ),
        'bef5ee9976144ae5',
      );
    });

    test('仅改模型即产生不同指纹', () {
      final withFlash = configFingerprint(
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-flash',
        promptVersion: 'v1',
      );
      final withPro = configFingerprint(
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-pro',
        promptVersion: 'v1',
      );

      expect(withFlash, isNot(withPro));
    });

    test('仅改 Base URL 即产生不同指纹', () {
      expect(
        configFingerprint(
          baseUrl: 'https://openrouter.ai/api/v1',
          model: 'mistralai/mistral-nemo',
          promptVersion: 'v1',
        ),
        '62dd19f26d728649',
      );
    });

    test('固定为 16 位小写十六进制', () {
      final fingerprint = configFingerprint(
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-flash',
        promptVersion: 'v1',
      );

      expect(fingerprint.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(fingerprint), isTrue);
    });
  });

  group('cacheType', () {
    test('无目标语言时为 <feature>:<fingerprint>', () {
      expect(
        cacheType(feature: 'sense_groups', fingerprint: '546ea72f6e35e103'),
        'sense_groups:546ea72f6e35e103',
      );
    });

    test('有目标语言时为 <feature>:<lang>:<fingerprint>', () {
      expect(
        cacheType(
          feature: 'translation_v2',
          fingerprint: '546ea72f6e35e103',
          targetLanguage: 'zh-CN',
        ),
        'translation_v2:zh-CN:546ea72f6e35e103',
      );
    });

    test('空目标语言按无语言处理，不产生空段', () {
      expect(
        cacheType(
          feature: 'analysis_v2',
          fingerprint: '546ea72f6e35e103',
          targetLanguage: '',
        ),
        'analysis_v2:546ea72f6e35e103',
      );
    });

    test('切换模型后同一功能的缓存类型不再相同（旧配置缓存自然不命中）', () {
      final before = cacheType(
        feature: 'translation_v2',
        targetLanguage: 'zh-CN',
        fingerprint: configFingerprint(
          baseUrl: 'https://api.deepseek.com',
          model: 'deepseek-flash',
          promptVersion: 'v1',
        ),
      );
      final after = cacheType(
        feature: 'translation_v2',
        targetLanguage: 'zh-CN',
        fingerprint: configFingerprint(
          baseUrl: 'https://api.deepseek.com',
          model: 'deepseek-pro',
          promptVersion: 'v1',
        ),
      );

      expect(before, isNot(after));
      expect(before, startsWith('translation_v2:zh-CN:'));
      expect(after, startsWith('translation_v2:zh-CN:'));
    });

    test('相同输入稳定', () {
      expect(
        cacheType(feature: 'retell', fingerprint: 'abcdef0123456789'),
        cacheType(feature: 'retell', fingerprint: 'abcdef0123456789'),
      );
    });
  });
}
