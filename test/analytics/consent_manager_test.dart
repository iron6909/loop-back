import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:loop_back/analytics/consent_manager.dart';

void main() {
  group('ConsentManager', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('默认同意（本期策略）', () {
      final manager = ConsentManager(prefs);
      expect(manager.hasConsented, isTrue);
    });

    test('撤回同意后 hasConsented 为 false', () async {
      final manager = ConsentManager(prefs);
      await manager.revokeConsent();
      expect(manager.hasConsented, isFalse);
    });

    test('撤回后重新同意', () async {
      final manager = ConsentManager(prefs);
      await manager.revokeConsent();
      expect(manager.hasConsented, isFalse);

      await manager.grantConsent();
      expect(manager.hasConsented, isTrue);
    });

    test('同意状态跨实例持久化', () async {
      final manager1 = ConsentManager(prefs);
      await manager1.revokeConsent();

      // 模拟 App 重启：用同一个 prefs 创建新实例
      final manager2 = ConsentManager(prefs);
      expect(manager2.hasConsented, isFalse);
    });
  });
}
