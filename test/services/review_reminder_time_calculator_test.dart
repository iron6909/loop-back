import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/services/review_reminder_time_calculator.dart';

void main() {
  group('FixedTimeReminderCalculator', () {
    const calculator = FixedTimeReminderCalculator(hour: 20, minute: 0);

    test('当前时间早于 20:00，返回当天 20:00', () {
      final now = DateTime(2026, 2, 25, 10, 30);
      final triggerAt = calculator.nextTriggerAt(now);
      expect(triggerAt, DateTime(2026, 2, 25, 20, 0));
    });

    test('当前时间晚于 20:00，返回次日 20:00', () {
      final now = DateTime(2026, 2, 25, 21, 15);
      final triggerAt = calculator.nextTriggerAt(now);
      expect(triggerAt, DateTime(2026, 2, 26, 20, 0));
    });
  });

  test('AdaptiveReminderTimeCalculator 当前回退到 fixed', () {
    const adaptive = AdaptiveReminderTimeCalculator(
      fallback: FixedTimeReminderCalculator(hour: 20, minute: 0),
    );
    final now = DateTime(2026, 2, 25, 8, 0);
    expect(adaptive.nextTriggerAt(now), DateTime(2026, 2, 25, 20, 0));
  });
}
