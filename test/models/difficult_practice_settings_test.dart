// DifficultPracticeSettings 模型单元测试。
// 验证默认值、copyWith、JSON 序列化和 pause 计算逻辑。
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/difficult_practice_settings.dart';
import 'package:loop_back/models/intensive_listen_settings.dart';

void main() {
  group('DifficultPracticeSettings', () {
    test('默认值', () {
      const settings = DifficultPracticeSettings();
      expect(settings.blindListenRepeatCount, 1);
      expect(settings.shadowReadingRepeatCount, 3);
      expect(settings.pauseMode, PauseMode.smart);
      expect(settings.fixedPauseSeconds, 3);
      expect(settings.pauseMultiplier, 2.0);
      expect(settings.playbackSpeed, 1.0);
    });

    test('copyWith 可更新播放速度', () {
      const settings = DifficultPracticeSettings();
      final updated = settings.copyWith(playbackSpeed: 0.9);
      expect(updated.playbackSpeed, 0.9);
      expect(updated.shadowReadingRepeatCount, 3);
    });

    test('入口播放速度选项符合统一 0.1 步进档位', () {
      expect(DifficultPracticeSettings.briefingPlaybackSpeedOptions, const [
        0.4,
        0.5,
        0.6,
        0.7,
        0.8,
        0.9,
        1.0,
        1.1,
        1.2,
        1.3,
        1.4,
        1.5,
        2.0,
      ]);
    });

    test('fromJson 解析超出范围的速度回退 1.0', () {
      final s = DifficultPracticeSettings.fromJson({'playbackSpeed': 3.0});
      expect(s.playbackSpeed, 1.0);
      final s2 = DifficultPracticeSettings.fromJson({'playbackSpeed': 0.1});
      expect(s2.playbackSpeed, 1.0);
      final s3 = DifficultPracticeSettings.fromJson({'playbackSpeed': 0.85});
      expect(s3.playbackSpeed, 0.9);
    });

    test('copyWith — 部分更新', () {
      const settings = DifficultPracticeSettings();
      final updated = settings.copyWith(
        blindListenRepeatCount: 5,
        shadowReadingRepeatCount: 2,
      );
      expect(updated.blindListenRepeatCount, 5);
      expect(updated.shadowReadingRepeatCount, 2);
      // 未更新字段保持默认
      expect(updated.pauseMode, PauseMode.smart);
      expect(updated.fixedPauseSeconds, 3);
    });

    test('copyWith — 更新停顿模式', () {
      const settings = DifficultPracticeSettings();
      final updated = settings.copyWith(
        pauseMode: PauseMode.fixed,
        fixedPauseSeconds: 10,
      );
      expect(updated.pauseMode, PauseMode.fixed);
      expect(updated.fixedPauseSeconds, 10);
    });

    group('toJson / fromJson', () {
      test('往返序列化', () {
        const original = DifficultPracticeSettings(
          blindListenRepeatCount: 3,
          shadowReadingRepeatCount: 5,
          pauseMode: PauseMode.multiplier,
          fixedPauseSeconds: 10,
          pauseMultiplier: 3.0,
        );

        final json = original.toJson();
        final restored = DifficultPracticeSettings.fromJson(json);

        expect(restored.blindListenRepeatCount, 3);
        expect(restored.shadowReadingRepeatCount, 5);
        expect(restored.pauseMode, PauseMode.multiplier);
        expect(restored.fixedPauseSeconds, 10);
        expect(restored.pauseMultiplier, 3.0);
      });

      test('非法值回退默认', () {
        final restored = DifficultPracticeSettings.fromJson({
          'blindListenRepeatCount': 'invalid',
          'shadowReadingRepeatCount': 99,
          'pauseMode': 'unknown',
          'fixedPauseSeconds': 999,
          'pauseMultiplier': 999.0,
        });

        expect(restored.blindListenRepeatCount, 1);
        expect(restored.shadowReadingRepeatCount, 50); // clamp to max
        expect(restored.pauseMode, PauseMode.smart);
        expect(restored.fixedPauseSeconds, 3);
        expect(restored.pauseMultiplier, 2.0);
      });

      test('0 作为无限重复保留', () {
        final restored = DifficultPracticeSettings.fromJson({
          'blindListenRepeatCount': 0,
          'shadowReadingRepeatCount': 0,
        });

        expect(restored.blindListenRepeatCount, 0);
        expect(restored.shadowReadingRepeatCount, 0);
      });

      test('空 JSON 回退默认', () {
        final restored = DifficultPracticeSettings.fromJson({});
        expect(restored.blindListenRepeatCount, 1);
        expect(restored.shadowReadingRepeatCount, 3);
        expect(restored.pauseMode, PauseMode.smart);
      });
    });

    group('calculateInterSentencePause', () {
      test('smart 模式 — clamp(1s + 0.6×句长, 2s, 20s)', () {
        const settings = DifficultPracticeSettings(pauseMode: PauseMode.smart);

        // 短句 500ms：1000 + 300 = 1300ms → clamp → 2000ms
        expect(
          settings.calculateInterSentencePause(
            const Duration(milliseconds: 500),
          ),
          const Duration(milliseconds: 2000),
        );

        // 中句 3000ms：1000 + 1800 = 2800ms
        expect(
          settings.calculateInterSentencePause(
            const Duration(milliseconds: 3000),
          ),
          const Duration(milliseconds: 2800),
        );

        // 长句 35000ms：1000 + 21000 = 22000ms → clamp → 20000ms
        expect(
          settings.calculateInterSentencePause(
            const Duration(milliseconds: 35000),
          ),
          const Duration(milliseconds: 20000),
        );
      });

      test('fixed 模式 — 固定秒数', () {
        const settings = DifficultPracticeSettings(
          pauseMode: PauseMode.fixed,
          fixedPauseSeconds: 10,
        );

        expect(
          settings.calculateInterSentencePause(
            const Duration(milliseconds: 3000),
          ),
          const Duration(seconds: 10),
        );
      });

      test('multiplier 模式 — 句长 × 倍数', () {
        const settings = DifficultPracticeSettings(
          pauseMode: PauseMode.multiplier,
          pauseMultiplier: 2.0,
        );

        expect(
          settings.calculateInterSentencePause(
            const Duration(milliseconds: 2000),
          ),
          const Duration(milliseconds: 4000),
        );
      });

      test('multiplier 模式 — 至少 1000ms', () {
        const settings = DifficultPracticeSettings(
          pauseMode: PauseMode.multiplier,
          pauseMultiplier: 1.0,
        );

        expect(
          settings.calculateInterSentencePause(
            const Duration(milliseconds: 500),
          ),
          const Duration(milliseconds: 1000),
        );
      });

      test('smart 模式 — 零时长返回最小 2000ms', () {
        const settings = DifficultPracticeSettings(pauseMode: PauseMode.smart);
        // 0ms：1000 + 0 = 1000ms → clamp → 2000ms
        expect(
          settings.calculateInterSentencePause(Duration.zero),
          const Duration(milliseconds: 2000),
        );
      });
    });
  });
}
