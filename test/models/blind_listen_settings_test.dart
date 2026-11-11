// 盲听设置模型测试
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/blind_listen_settings.dart';
import 'package:loop_back/models/intensive_listen_settings.dart'
    show PauseMode, ShadowingControlMode;

void main() {
  group('BlindListenSettings', () {
    test('默认值验证', () {
      const settings = BlindListenSettings();

      expect(settings.repeatCount, 1);
      expect(settings.pauseMode, PauseMode.multiplier);
      expect(settings.fixedPauseSeconds, 10);
      expect(settings.pauseMultiplier, 0.5);
      expect(settings.controlMode, ShadowingControlMode.auto);
      expect(settings.playbackSpeed, 1.0);
      expect(settings.isManualMode, false);
    });

    test('isManualMode getter', () {
      const auto = BlindListenSettings();
      expect(auto.isManualMode, false);

      const manual = BlindListenSettings(
        controlMode: ShadowingControlMode.manual,
      );
      expect(manual.isManualMode, true);
    });

    test('copyWith 更新 controlMode', () {
      const settings = BlindListenSettings();
      final updated = settings.copyWith(
        controlMode: ShadowingControlMode.manual,
      );

      expect(updated.controlMode, ShadowingControlMode.manual);
      expect(updated.isManualMode, true);
      // 其他字段保持不变
      expect(updated.repeatCount, 1);
      expect(updated.pauseMode, PauseMode.multiplier);
    });

    test('copyWith 不传 controlMode 时保持原值', () {
      const manual = BlindListenSettings(
        controlMode: ShadowingControlMode.manual,
      );
      final same = manual.copyWith(repeatCount: 3);

      expect(same.controlMode, ShadowingControlMode.manual);
      expect(same.isManualMode, true);
      expect(same.repeatCount, 3);
    });

    test('copyWith 更新所有字段', () {
      const settings = BlindListenSettings();
      final updated = settings.copyWith(
        repeatCount: 3,
        pauseMode: PauseMode.fixed,
        fixedPauseSeconds: 30,
        pauseMultiplier: 2.0,
        controlMode: ShadowingControlMode.manual,
        playbackSpeed: 1.3,
      );

      expect(updated.repeatCount, 3);
      expect(updated.pauseMode, PauseMode.fixed);
      expect(updated.fixedPauseSeconds, 30);
      expect(updated.pauseMultiplier, 2.0);
      expect(updated.controlMode, ShadowingControlMode.manual);
      expect(updated.playbackSpeed, 1.3);
    });

    test('toJson / fromJson 保留 0=∞', () {
      const settings = BlindListenSettings(repeatCount: 0);
      final restored = BlindListenSettings.fromJson(settings.toJson());
      expect(restored.repeatCount, 0);
    });

    test('入口播放速度选项符合统一 0.1 步进档位', () {
      expect(BlindListenSettings.briefingPlaybackSpeedOptions, const [
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

    test('calculatePauseDuration 在各模式下正确计算', () {
      const duration = Duration(seconds: 10);

      // multiplier 模式
      const multiplier = BlindListenSettings(
        pauseMode: PauseMode.multiplier,
        pauseMultiplier: 2.0,
      );
      expect(
        multiplier.calculatePauseDuration(duration),
        const Duration(seconds: 20),
      );

      // fixed 模式
      const fixed = BlindListenSettings(
        pauseMode: PauseMode.fixed,
        fixedPauseSeconds: 15,
      );
      expect(
        fixed.calculatePauseDuration(duration),
        const Duration(seconds: 15),
      );

      // smart 模式
      const smart = BlindListenSettings(pauseMode: PauseMode.smart);
      final smartResult = smart.calculatePauseDuration(duration);
      // smart = 0.5 × 10s = 5s
      expect(smartResult, const Duration(seconds: 5));
    });

    test('fromMultiplier 工厂正确创建', () {
      final smartSettings = BlindListenSettings.fromMultiplier(-1.0);
      expect(smartSettings.pauseMode, PauseMode.smart);

      final multiplierSettings = BlindListenSettings.fromMultiplier(2.0);
      expect(multiplierSettings.pauseMode, PauseMode.multiplier);
      expect(multiplierSettings.pauseMultiplier, 2.0);
    });
  });
}
