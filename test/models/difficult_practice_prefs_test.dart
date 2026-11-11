/// DifficultPracticePrefs 模型单元测试
///
/// 覆盖:resolve 叠加(可空覆盖 vs 默认/智能默认)、toJson/fromJson round-trip、
/// 脏数据防御性回退、copyWith 细粒度叠加。
library;

import 'package:loop_back/models/difficult_practice_prefs.dart';
import 'package:loop_back/models/intensive_listen_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolve 叠加', () {
    test('空偏好:速度用智能默认,其余用静态默认', () {
      const prefs = DifficultPracticePrefs.empty();
      final s = prefs.resolve(smartSpeed: 0.9);

      expect(s.playbackSpeed, 0.9); // 速度=智能默认
      expect(s.controlMode, ShadowingControlMode.auto);
      expect(s.blindListenRepeatCount, 1);
      expect(s.shadowReadingRepeatCount, 3);
      expect(s.pauseMode, PauseMode.smart);
      expect(s.fixedPauseSeconds, 3);
      expect(s.pauseMultiplier, 2.0);
    });

    test('设过的字段用设值,未设的字段仍按各自默认', () {
      const prefs = DifficultPracticePrefs(
        pauseMode: PauseMode.fixed,
        fixedPauseSeconds: 5,
      );
      final s = prefs.resolve(smartSpeed: 0.8);

      expect(s.pauseMode, PauseMode.fixed);
      expect(s.fixedPauseSeconds, 5);
      // 速度未设 → 仍取智能默认(不被冻结)
      expect(s.playbackSpeed, 0.8);
      expect(s.shadowReadingRepeatCount, 3);
    });

    test('显式设速度后,resolve 用设值而非智能默认', () {
      const prefs = DifficultPracticePrefs(playbackSpeed: 1.2);
      expect(prefs.resolve(smartSpeed: 0.8).playbackSpeed, 1.2);
    });

    test('遍数 / 倍数模式 / 控制模式覆盖', () {
      const prefs = DifficultPracticePrefs(
        controlMode: ShadowingControlMode.manual,
        blindListenRepeatCount: 0,
        shadowReadingRepeatCount: 5,
        pauseMode: PauseMode.multiplier,
        pauseMultiplier: 3.0,
      );
      final s = prefs.resolve(smartSpeed: 1.0);
      expect(s.controlMode, ShadowingControlMode.manual);
      expect(s.blindListenRepeatCount, 0);
      expect(s.shadowReadingRepeatCount, 5);
      expect(s.pauseMode, PauseMode.multiplier);
      expect(s.pauseMultiplier, 3.0);
    });
  });

  group('toJson/fromJson', () {
    test('稀疏序列化:只写非空字段', () {
      const prefs = DifficultPracticePrefs(
        pauseMode: PauseMode.fixed,
        fixedPauseSeconds: 5,
      );
      final json = prefs.toJson();
      expect(json.keys.toSet(), {'pauseMode', 'fixedPauseSeconds'});
      expect(json['pauseMode'], 'fixed');
      expect(json['fixedPauseSeconds'], 5);
    });

    test('round-trip 还原相等', () {
      const prefs = DifficultPracticePrefs(
        controlMode: ShadowingControlMode.manual,
        blindListenRepeatCount: 2,
        shadowReadingRepeatCount: 4,
        pauseMode: PauseMode.multiplier,
        pauseMultiplier: 2.5,
        playbackSpeed: 0.9,
      );
      expect(DifficultPracticePrefs.fromJson(prefs.toJson()), prefs);
    });

    test('空偏好 round-trip 仍为空', () {
      const prefs = DifficultPracticePrefs.empty();
      expect(
        DifficultPracticePrefs.fromJson(prefs.toJson()),
        const DifficultPracticePrefs.empty(),
      );
    });
  });

  group('防御性解析', () {
    test('字段缺失 → 对应字段为 null', () {
      final prefs = DifficultPracticePrefs.fromJson(const {});
      expect(prefs, const DifficultPracticePrefs.empty());
    });

    test('越档/非法值 → 视作未设(null)', () {
      final prefs = DifficultPracticePrefs.fromJson(const {
        'controlMode': 'xx',
        'blindListenRepeatCount': -3,
        'shadowReadingRepeatCount': -1,
        'pauseMode': 'bogus',
        'fixedPauseSeconds': 9, // 不在档位
        'pauseMultiplier': 9.9, // 不在档位
        'playbackSpeed': 'fast', // 非 num
      });
      expect(prefs, const DifficultPracticePrefs.empty());
    });

    test('遍数 > 50 截到 50，新增档位可保留', () {
      final prefs = DifficultPracticePrefs.fromJson(const {
        'blindListenRepeatCount': 99,
        'shadowReadingRepeatCount': 50,
      });
      expect(prefs.blindListenRepeatCount, 50);
      expect(prefs.shadowReadingRepeatCount, 50);
      for (final count in [20, 30, 40, 50]) {
        final value = DifficultPracticePrefs.fromJson({
          'blindListenRepeatCount': count,
          'shadowReadingRepeatCount': count,
        });
        expect(value.blindListenRepeatCount, count);
        expect(value.shadowReadingRepeatCount, count);
      }
    });

    test('遍数 0 表示无限,合法保留', () {
      final prefs = DifficultPracticePrefs.fromJson(const {
        'blindListenRepeatCount': 0,
      });
      expect(prefs.blindListenRepeatCount, 0);
    });

    test('速度归一化到档位', () {
      final prefs = DifficultPracticePrefs.fromJson(const {
        'playbackSpeed': 0.93,
      });
      expect(prefs.playbackSpeed, 0.9);
    });
  });

  group('copyWith 细粒度叠加', () {
    test('只改传入字段,其余保留', () {
      const base = DifficultPracticePrefs(playbackSpeed: 1.0);
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
