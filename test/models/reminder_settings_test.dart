import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/reminder_settings.dart';

void main() {
  group('ReminderSettings', () {
    test('默认值与硬编码行为一致', () {
      const settings = ReminderSettings();
      expect(settings.savedReviewReminderEnabled, isTrue);
      expect(settings.savedReviewReminderHour, 20);
      expect(settings.savedReviewReminderMinute, 0);
      expect(settings.perAudioReminderEnabled, isTrue);
    });

    test('formattedTime 格式化为零填充时间', () {
      const settings = ReminderSettings(
        savedReviewReminderHour: 8,
        savedReviewReminderMinute: 5,
      );
      expect(settings.formattedTime, '08:05');
    });

    test('formattedTime 两位数时间不多填充', () {
      const settings = ReminderSettings(
        savedReviewReminderHour: 20,
        savedReviewReminderMinute: 30,
      );
      expect(settings.formattedTime, '20:30');
    });

    group('copyWith', () {
      test('修改单个字段，其余保持不变', () {
        const original = ReminderSettings();
        final modified = original.copyWith(savedReviewReminderHour: 8);
        expect(modified.savedReviewReminderHour, 8);
        expect(modified.savedReviewReminderEnabled, isTrue);
        expect(modified.savedReviewReminderMinute, 0);
        expect(modified.perAudioReminderEnabled, isTrue);
      });

      test('修改所有字段', () {
        const original = ReminderSettings();
        final modified = original.copyWith(
          savedReviewReminderEnabled: false,
          savedReviewReminderHour: 7,
          savedReviewReminderMinute: 30,
          perAudioReminderEnabled: false,
        );
        expect(modified.savedReviewReminderEnabled, isFalse);
        expect(modified.savedReviewReminderHour, 7);
        expect(modified.savedReviewReminderMinute, 30);
        expect(modified.perAudioReminderEnabled, isFalse);
      });

      test('不传参数返回等值对象', () {
        const original = ReminderSettings(
          savedReviewReminderHour: 9,
          savedReviewReminderMinute: 15,
        );
        final copied = original.copyWith();
        expect(copied, equals(original));
      });
    });

    group('toJson / fromJson 往返', () {
      test('完整往返', () {
        const original = ReminderSettings(
          savedReviewReminderEnabled: false,
          savedReviewReminderHour: 7,
          savedReviewReminderMinute: 45,
          perAudioReminderEnabled: false,
        );
        final json = original.toJson();
        final restored = ReminderSettings.fromJson(json);
        expect(restored, equals(original));
      });

      test('空 JSON 返回默认值', () {
        final settings = ReminderSettings.fromJson({});
        expect(settings, equals(const ReminderSettings()));
      });
    });

    group('fromJson 防御性解析', () {
      test('hour 超出范围回退默认 20', () {
        final settings = ReminderSettings.fromJson({'dailyReminderHour': 25});
        expect(settings.savedReviewReminderHour, 20);
      });

      test('hour 为负数回退默认 20', () {
        final settings = ReminderSettings.fromJson({'dailyReminderHour': -1});
        expect(settings.savedReviewReminderHour, 20);
      });

      test('minute 超出范围回退默认 0', () {
        final settings = ReminderSettings.fromJson({'dailyReminderMinute': 60});
        expect(settings.savedReviewReminderMinute, 0);
      });

      test('minute 为负数回退默认 0', () {
        final settings = ReminderSettings.fromJson({'dailyReminderMinute': -5});
        expect(settings.savedReviewReminderMinute, 0);
      });

      test('hour 非 int 类型回退默认 20', () {
        final settings = ReminderSettings.fromJson({'dailyReminderHour': '8'});
        expect(settings.savedReviewReminderHour, 20);
      });

      test('bool 字段非 bool 类型回退默认 true', () {
        final settings = ReminderSettings.fromJson({
          'dailyReminderEnabled': 'yes',
          'perAudioReminderEnabled': 1,
        });
        expect(settings.savedReviewReminderEnabled, isTrue);
        expect(settings.perAudioReminderEnabled, isTrue);
      });

      test('合法边界值 hour=0 minute=0', () {
        final settings = ReminderSettings.fromJson({
          'dailyReminderHour': 0,
          'dailyReminderMinute': 0,
        });
        expect(settings.savedReviewReminderHour, 0);
        expect(settings.savedReviewReminderMinute, 0);
      });

      test('合法边界值 hour=23 minute=59', () {
        final settings = ReminderSettings.fromJson({
          'dailyReminderHour': 23,
          'dailyReminderMinute': 59,
        });
        expect(settings.savedReviewReminderHour, 23);
        expect(settings.savedReviewReminderMinute, 59);
      });
    });

    group('equality', () {
      test('相同值相等', () {
        const a = ReminderSettings(savedReviewReminderHour: 8);
        const b = ReminderSettings(savedReviewReminderHour: 8);
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('不同值不等', () {
        const a = ReminderSettings(savedReviewReminderHour: 8);
        const b = ReminderSettings(savedReviewReminderHour: 20);
        expect(a, isNot(equals(b)));
      });
    });
  });
}
