/// stage_settings_overrides 保留定义测试
///
/// 存储已迁移到按槽位 typed 偏好;本文件仅覆盖保留的通用定义:
/// 槽位 key 拼装 [stageSlotKey] 与入口停顿值类型 [BriefingPauseChoice]。
library;

import 'package:loop_back/database/enums.dart';
import 'package:loop_back/models/intensive_listen_settings.dart' show PauseMode;
import 'package:loop_back/models/stage_settings_overrides.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('stageSlotKey', () {
    test('带轮次:子阶段:轮次', () {
      expect(
        stageSlotKey(StageSettingsSlots.blindListen, LearningStage.review2),
        'blindListen:review2',
      );
    });

    test('无轮次(null)→ none 后缀', () {
      expect(
        stageSlotKey(StageSettingsSlots.bookmarkReview, null),
        'bookmarkReview:none',
      );
    });

    test('同子阶段不同轮次 key 不同', () {
      final r2 = stageSlotKey(
        StageSettingsSlots.reviewDifficultPractice,
        LearningStage.review2,
      );
      final r14 = stageSlotKey(
        StageSettingsSlots.reviewDifficultPractice,
        LearningStage.review14,
      );
      expect(r2 == r14, isFalse);
    });
  });

  group('BriefingPauseChoice', () {
    test('值相等', () {
      expect(
        const BriefingPauseChoice.fixed(5),
        const BriefingPauseChoice.fixed(5),
      );
      expect(
        const BriefingPauseChoice.fixed(5) ==
            const BriefingPauseChoice.fixed(7),
        isFalse,
      );
      expect(
        const BriefingPauseChoice.smart() ==
            const BriefingPauseChoice.multiplier(2.0),
        isFalse,
      );
    });

    test('mode 与字段', () {
      expect(const BriefingPauseChoice.fixed(5).mode, PauseMode.fixed);
      expect(const BriefingPauseChoice.fixed(5).fixedSeconds, 5);
      expect(const BriefingPauseChoice.multiplier(2.0).multiplier, 2.0);
    });

    test('legacyPauseMultiplier:仅倍数给真实值,其余 -1', () {
      expect(
        const BriefingPauseChoice.multiplier(2.0).legacyPauseMultiplier,
        2.0,
      );
      expect(const BriefingPauseChoice.fixed(10).legacyPauseMultiplier, -1.0);
      expect(const BriefingPauseChoice.smart().legacyPauseMultiplier, -1.0);
    });
  });
}
