// 精听设置模型测试
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/intensive_listen_settings.dart';

void main() {
  group('IntensiveListenSettings', () {
    test('默认值验证', () {
      const settings = IntensiveListenSettings();

      expect(settings.repeatCount, 1);
      expect(settings.annotationReplayUsesRepeatCount, false);
      expect(settings.pauseMode, PauseMode.smart);
      expect(settings.fixedPauseSeconds, 3);
      expect(settings.pauseMultiplier, 2.0);
      expect(settings.playbackSpeed, 1.0);
    });

    test('copyWith 可更新播放速度', () {
      const settings = IntensiveListenSettings();
      final updated = settings.copyWith(playbackSpeed: 1.3);

      expect(updated.playbackSpeed, 1.3);
      expect(updated.repeatCount, 1);
    });

    test('copyWith 可更新讲解页循环开关', () {
      final updated = const IntensiveListenSettings().copyWith(
        annotationReplayUsesRepeatCount: true,
      );

      expect(updated.annotationReplayUsesRepeatCount, true);
      expect(updated.repeatCount, 1);
    });

    test('入口播放速度选项符合统一 0.1 步进档位', () {
      expect(IntensiveListenSettings.briefingPlaybackSpeedOptions, const [
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
      final s = IntensiveListenSettings.fromJson({'playbackSpeed': 3.0});
      expect(s.playbackSpeed, 1.0);
      final s2 = IntensiveListenSettings.fromJson({'playbackSpeed': 0.1});
      expect(s2.playbackSpeed, 1.0);
      final s3 = IntensiveListenSettings.fromJson({'playbackSpeed': 1.25});
      expect(s3.playbackSpeed, 1.3);
    });

    test('copyWith 更新单个字段', () {
      const settings = IntensiveListenSettings();
      final updated = settings.copyWith(repeatCount: 3);

      expect(updated.repeatCount, 3);
      expect(updated.pauseMode, PauseMode.smart);
      expect(updated.fixedPauseSeconds, 3);
      expect(updated.pauseMultiplier, 2.0);
    });

    test('copyWith 更新所有字段', () {
      const settings = IntensiveListenSettings();
      final updated = settings.copyWith(
        repeatCount: 5,
        pauseMode: PauseMode.fixed,
        fixedPauseSeconds: 10,
        pauseMultiplier: 3.0,
      );

      expect(updated.repeatCount, 5);
      expect(updated.pauseMode, PauseMode.fixed);
      expect(updated.fixedPauseSeconds, 10);
      expect(updated.pauseMultiplier, 3.0);
    });

    test('copyWith 不传参数时保持原值', () {
      final original = const IntensiveListenSettings().copyWith(
        repeatCount: 7,
        pauseMode: PauseMode.multiplier,
      );
      final same = original.copyWith();

      expect(same.repeatCount, 7);
      expect(same.pauseMode, PauseMode.multiplier);
    });

    test('toJson 序列化正确', () {
      const settings = IntensiveListenSettings(
        repeatCount: 3,
        pauseMode: PauseMode.fixed,
        fixedPauseSeconds: 10,
        pauseMultiplier: 1.5,
      );

      final json = settings.toJson();
      expect(json['repeatCount'], 3);
      expect(json['annotationReplayUsesRepeatCount'], false);
      expect(json['pauseMode'], 'fixed');
      expect(json['fixedPauseSeconds'], 10);
      expect(json['pauseMultiplier'], 1.5);
    });

    test('fromJson 往返验证', () {
      const original = IntensiveListenSettings(
        repeatCount: 5,
        pauseMode: PauseMode.multiplier,
        fixedPauseSeconds: 15,
        pauseMultiplier: 3.0,
      );

      final restored = IntensiveListenSettings.fromJson(original.toJson());
      expect(restored.repeatCount, original.repeatCount);
      expect(restored.pauseMode, original.pauseMode);
      expect(restored.fixedPauseSeconds, original.fixedPauseSeconds);
      expect(restored.pauseMultiplier, original.pauseMultiplier);
    });

    test('fromJson 往返讲解页循环开关', () {
      const original = IntensiveListenSettings(
        annotationReplayUsesRepeatCount: true,
      );

      final restored = IntensiveListenSettings.fromJson(original.toJson());
      expect(restored.annotationReplayUsesRepeatCount, true);
    });

    test('fromJson 默认值往返', () {
      const original = IntensiveListenSettings();
      final restored = IntensiveListenSettings.fromJson(original.toJson());

      expect(restored.repeatCount, 1);
      expect(restored.pauseMode, PauseMode.smart);
      expect(restored.fixedPauseSeconds, 3);
      expect(restored.pauseMultiplier, 2.0);
    });

    group('fromJson 防御性解析', () {
      test('空 JSON 回退默认', () {
        final settings = IntensiveListenSettings.fromJson({});

        expect(settings.repeatCount, 1);
        expect(settings.pauseMode, PauseMode.smart);
        expect(settings.fixedPauseSeconds, 3);
        expect(settings.pauseMultiplier, 2.0);
      });

      test('repeatCount 非 int 回退默认', () {
        final settings = IntensiveListenSettings.fromJson({
          'repeatCount': 'abc',
        });
        expect(settings.repeatCount, 1);
      });

      test('讲解页循环开关非 bool 回退关闭', () {
        final settings = IntensiveListenSettings.fromJson({
          'annotationReplayUsesRepeatCount': 'true',
        });
        expect(settings.annotationReplayUsesRepeatCount, false);
      });

      test('repeatCount 支持新增档位、0=∞ 且超出范围被 clamp', () {
        expect(
          IntensiveListenSettings.fromJson({'repeatCount': 0}).repeatCount,
          0,
        );
        expect(
          IntensiveListenSettings.fromJson({'repeatCount': -5}).repeatCount,
          1,
        );
        for (final count in [20, 30, 40, 50]) {
          expect(
            IntensiveListenSettings.fromJson({
              'repeatCount': count,
            }).repeatCount,
            count,
          );
        }
        expect(
          IntensiveListenSettings.fromJson({'repeatCount': 99}).repeatCount,
          50,
        );
      });

      test('pauseMode 非法值回退 smart', () {
        expect(
          IntensiveListenSettings.fromJson({'pauseMode': 'unknown'}).pauseMode,
          PauseMode.smart,
        );
        expect(
          IntensiveListenSettings.fromJson({'pauseMode': 123}).pauseMode,
          PauseMode.smart,
        );
      });

      test('fixedPauseSeconds 不在可选列表中回退 3', () {
        expect(
          IntensiveListenSettings.fromJson({
            'fixedPauseSeconds': 4,
          }).fixedPauseSeconds,
          3,
        );
        expect(
          IntensiveListenSettings.fromJson({
            'fixedPauseSeconds': 'abc',
          }).fixedPauseSeconds,
          3,
        );
      });

      test('fixedPauseSeconds 在可选列表中正常解析', () {
        expect(
          IntensiveListenSettings.fromJson({
            'fixedPauseSeconds': 30,
          }).fixedPauseSeconds,
          30,
        );
      });

      test('pauseMultiplier 不在可选列表中回退 2.0', () {
        expect(
          IntensiveListenSettings.fromJson({
            'pauseMultiplier': 1.3,
          }).pauseMultiplier,
          2.0,
        );
        expect(
          IntensiveListenSettings.fromJson({
            'pauseMultiplier': 'abc',
          }).pauseMultiplier,
          2.0,
        );
      });

      test('pauseMultiplier 在可选列表中正常解析', () {
        expect(
          IntensiveListenSettings.fromJson({
            'pauseMultiplier': 4.0,
          }).pauseMultiplier,
          4.0,
        );
      });
    });

    test('fixedPauseOptions 包含预期值', () {
      expect(IntensiveListenSettings.fixedPauseOptions, contains(1));
      expect(IntensiveListenSettings.fixedPauseOptions, contains(2));
      expect(IntensiveListenSettings.fixedPauseOptions, contains(60));
      expect(IntensiveListenSettings.fixedPauseOptions.length, 16);
    });

    test('multiplierOptions 包含预期值', () {
      expect(IntensiveListenSettings.multiplierOptions, contains(1.0));
      expect(IntensiveListenSettings.multiplierOptions, contains(5.0));
      expect(IntensiveListenSettings.multiplierOptions.length, 7);
    });

    group('ShadowingControlMode', () {
      test('默认控制模式为 auto', () {
        const settings = IntensiveListenSettings();
        expect(settings.controlMode, ShadowingControlMode.auto);
        expect(settings.isManualMode, false);
      });

      test('copyWith 更新控制模式', () {
        const settings = IntensiveListenSettings();
        final manual = settings.copyWith(
          controlMode: ShadowingControlMode.manual,
        );
        expect(manual.controlMode, ShadowingControlMode.manual);
        expect(manual.isManualMode, true);
        // 其他字段不变
        expect(manual.repeatCount, 1);
        expect(manual.pauseMode, PauseMode.smart);
      });

      test('toJson 序列化控制模式', () {
        const settings = IntensiveListenSettings(
          controlMode: ShadowingControlMode.manual,
        );
        expect(settings.toJson()['controlMode'], 'manual');

        const autoSettings = IntensiveListenSettings();
        expect(autoSettings.toJson()['controlMode'], 'auto');
      });

      test('fromJson 往返验证控制模式', () {
        const original = IntensiveListenSettings(
          controlMode: ShadowingControlMode.manual,
        );
        final restored = IntensiveListenSettings.fromJson(original.toJson());
        expect(restored.controlMode, ShadowingControlMode.manual);
      });

      test('fromJson 控制模式非法值回退 auto', () {
        expect(
          IntensiveListenSettings.fromJson({
            'controlMode': 'unknown',
          }).controlMode,
          ShadowingControlMode.auto,
        );
        expect(
          IntensiveListenSettings.fromJson({'controlMode': 123}).controlMode,
          ShadowingControlMode.auto,
        );
      });

      test('fromJson 缺少控制模式字段回退 auto', () {
        final settings = IntensiveListenSettings.fromJson({});
        expect(settings.controlMode, ShadowingControlMode.auto);
      });

      test('isManualMode 便捷属性', () {
        expect(
          const IntensiveListenSettings(
            controlMode: ShadowingControlMode.auto,
          ).isManualMode,
          false,
        );
        expect(
          const IntensiveListenSettings(
            controlMode: ShadowingControlMode.manual,
          ).isManualMode,
          true,
        );
      });
    });
  });
}
