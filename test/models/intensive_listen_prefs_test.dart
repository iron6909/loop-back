/// IntensiveListenPrefs 模型单元测试
///
/// 覆盖:resolve 叠加(可空覆盖 vs 默认/智能默认)、toJson/fromJson round-trip、
/// 脏数据防御性回退、copyWith 细粒度叠加。
library;

import 'package:loop_back/models/intensive_listen_prefs.dart';
import 'package:loop_back/models/intensive_listen_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolve 叠加', () {
    test('空偏好:速度用智能默认,其余用静态默认', () {
      const prefs = IntensiveListenPrefs.empty();
      final s = prefs.resolve(smartSpeed: 0.9);

      expect(s.playbackSpeed, 0.9); // 速度=智能默认
      expect(s.pauseMode, PauseMode.smart);
      expect(s.fixedPauseSeconds, 3);
      expect(s.pauseMultiplier, 2.0);
      expect(s.controlMode, ShadowingControlMode.auto);
      expect(s.repeatCount, 1);
      expect(s.annotationReplayUsesRepeatCount, false);
    });

    test('设过的字段用设值,未设的字段仍按各自默认', () {
      const prefs = IntensiveListenPrefs(
        pauseMode: PauseMode.fixed,
        fixedPauseSeconds: 5,
      );
      final s = prefs.resolve(smartSpeed: 0.8);

      expect(s.pauseMode, PauseMode.fixed);
      expect(s.fixedPauseSeconds, 5);
      // 速度未设 → 仍取智能默认(不被冻结)
      expect(s.playbackSpeed, 0.8);
    });

    test('显式设速度后,resolve 用设值而非智能默认', () {
      const prefs = IntensiveListenPrefs(playbackSpeed: 1.2);
      expect(prefs.resolve(smartSpeed: 0.8).playbackSpeed, 1.2);
    });

    test('倍数模式与控制模式覆盖', () {
      const prefs = IntensiveListenPrefs(
        pauseMode: PauseMode.multiplier,
        pauseMultiplier: 3.0,
        controlMode: ShadowingControlMode.manual,
        repeatCount: 0,
      );
      final s = prefs.resolve(smartSpeed: 1.0);
      expect(s.pauseMode, PauseMode.multiplier);
      expect(s.pauseMultiplier, 3.0);
      expect(s.controlMode, ShadowingControlMode.manual);
      expect(s.repeatCount, 0);
    });
  });

  group('toJson/fromJson', () {
    test('稀疏序列化:只写非空字段', () {
      const prefs = IntensiveListenPrefs(
        pauseMode: PauseMode.fixed,
        fixedPauseSeconds: 5,
      );
      final json = prefs.toJson();
      expect(json.keys.toSet(), {'pauseMode', 'fixedPauseSeconds'});
      expect(json['pauseMode'], 'fixed');
      expect(json['fixedPauseSeconds'], 5);
    });

    test('round-trip 还原相等', () {
      const prefs = IntensiveListenPrefs(
        playbackSpeed: 0.9,
        pauseMode: PauseMode.multiplier,
        pauseMultiplier: 2.5,
        controlMode: ShadowingControlMode.manual,
        repeatCount: 3,
        annotationReplayUsesRepeatCount: true,
      );
      expect(IntensiveListenPrefs.fromJson(prefs.toJson()), prefs);
    });

    test('空偏好 round-trip 仍为空', () {
      const prefs = IntensiveListenPrefs.empty();
      expect(
        IntensiveListenPrefs.fromJson(prefs.toJson()),
        const IntensiveListenPrefs.empty(),
      );
    });
  });

  group('防御性解析', () {
    test('字段缺失 → 对应字段为 null', () {
      final prefs = IntensiveListenPrefs.fromJson(const {});
      expect(prefs, const IntensiveListenPrefs.empty());
    });

    test('越档/非法值 → 视作未设(null)', () {
      final prefs = IntensiveListenPrefs.fromJson(const {
        'pauseMode': 'bogus',
        'fixedPauseSeconds': 9, // 不在档位
        'pauseMultiplier': 9.9, // 不在档位
        'controlMode': 'xx',
        'repeatCount': -3,
        'playbackSpeed': 'fast', // 非 num
      });
      expect(prefs, const IntensiveListenPrefs.empty());
    });

    test('repeatCount > 50 截到 50，新增档位可保留', () {
      for (final count in [20, 30, 40, 50]) {
        expect(
          IntensiveListenPrefs.fromJson({'repeatCount': count}).repeatCount,
          count,
        );
      }
      final prefs = IntensiveListenPrefs.fromJson(const {'repeatCount': 99});
      expect(prefs.repeatCount, 50);
    });

    test('速度归一化到档位', () {
      final prefs = IntensiveListenPrefs.fromJson(const {
        'playbackSpeed': 0.93,
      });
      expect(prefs.playbackSpeed, 0.9);
    });
  });

  group('copyWith 细粒度叠加', () {
    test('只改传入字段,其余保留', () {
      const base = IntensiveListenPrefs(playbackSpeed: 1.0);
      final next = base.copyWith(
        pauseMode: PauseMode.fixed,
        fixedPauseSeconds: 5,
      );
      expect(next.playbackSpeed, 1.0);
      expect(next.pauseMode, PauseMode.fixed);
      expect(next.fixedPauseSeconds, 5);
    });
  });
}
