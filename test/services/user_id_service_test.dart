import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:loop_back/services/user_id_service.dart';

class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late MockFlutterSecureStorage mockSecure;
  late SharedPreferences prefs;

  setUp(() {
    mockSecure = MockFlutterSecureStorage();
  });

  group('initUserIdService', () {
    test('SecureStorage 已有值时直接返回，不写入', () async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();

      when(
        () => mockSecure.read(key: 'anonymous_id'),
      ).thenAnswer((_) async => 'existing-id');

      final id = await initUserIdService(prefs, secureStorage: mockSecure);

      expect(id, 'existing-id');
      verifyNever(
        () => mockSecure.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      );
    });

    test('SecureStorage 无值但 SP 有旧值时迁移并删除 SP', () async {
      SharedPreferences.setMockInitialValues({'anonymous_id': 'legacy-id'});
      prefs = await SharedPreferences.getInstance();

      when(
        () => mockSecure.read(key: 'anonymous_id'),
      ).thenAnswer((_) async => null);
      when(
        () => mockSecure.write(key: 'anonymous_id', value: 'legacy-id'),
      ).thenAnswer((_) async {});

      final id = await initUserIdService(prefs, secureStorage: mockSecure);

      expect(id, 'legacy-id');
      // 验证写入 SecureStorage
      verify(
        () => mockSecure.write(key: 'anonymous_id', value: 'legacy-id'),
      ).called(1);
      // 验证 SP 旧值已删除
      expect(prefs.getString('anonymous_id'), isNull);
    });

    test('两者都没有时生成新 UUID 并写入 SecureStorage', () async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();

      when(
        () => mockSecure.read(key: 'anonymous_id'),
      ).thenAnswer((_) async => null);
      when(
        () => mockSecure.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenAnswer((_) async {});

      final id = await initUserIdService(prefs, secureStorage: mockSecure);

      // 应该是合法的 UUID v4 格式
      expect(
        id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      verify(() => mockSecure.write(key: 'anonymous_id', value: id)).called(1);
    });
  });
}
