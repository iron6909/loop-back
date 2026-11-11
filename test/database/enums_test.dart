/// 学习枚举测试
///
/// 覆盖 `kRetellSubStages` 常量集合 / `isRetellSubStage` 工具函数 /
/// `LearningStage.allSubStages` 全量子步骤定义。
library;

import 'package:loop_back/database/enums.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('kRetellSubStages', () {
    test('包含全部 3 类复述子阶段', () {
      expect(kRetellSubStages, {
        SubStageType.retell,
        SubStageType.reviewRetellParagraph,
        SubStageType.reviewRetellSummary,
      });
    });

    test('不包含非复述子阶段', () {
      expect(kRetellSubStages.contains(SubStageType.blindListen), isFalse);
      expect(kRetellSubStages.contains(SubStageType.intensiveListen), isFalse);
      expect(kRetellSubStages.contains(SubStageType.listenAndRepeat), isFalse);
      expect(
        kRetellSubStages.contains(SubStageType.reviewDifficultPractice),
        isFalse,
      );
    });
  });

  group('isRetellSubStage', () {
    test('3 类复述返回 true', () {
      expect(isRetellSubStage(SubStageType.retell), isTrue);
      expect(isRetellSubStage(SubStageType.reviewRetellParagraph), isTrue);
      expect(isRetellSubStage(SubStageType.reviewRetellSummary), isTrue);
    });

    test('非复述返回 false', () {
      expect(isRetellSubStage(SubStageType.blindListen), isFalse);
      expect(isRetellSubStage(SubStageType.listenAndRepeat), isFalse);
      expect(isRetellSubStage(SubStageType.reviewDifficultPractice), isFalse);
    });
  });

  group('LearningStage.allSubStages', () {
    test('firstLearn 4 个子步骤（v2 规范顺序）', () {
      expect(LearningStage.firstLearn.allSubStages, [
        SubStageType.intensiveListen,
        SubStageType.listenAndRepeat,
        SubStageType.blindListen,
        SubStageType.retell,
      ]);
    });

    test('review0 包含 v1 ∪ v2 的并集 3 项（真实 plan 由 LearningPlan 按版本派生）', () {
      expect(LearningStage.review0.allSubStages, [
        SubStageType.reviewDifficultPractice,
        SubStageType.blindListen,
        SubStageType.reviewRetellParagraph,
      ]);
    });

    test('review28 v1 ∪ v2 并集 4 项（v1 summary + v2 paragraph 都保留）', () {
      expect(LearningStage.review28.allSubStages, [
        SubStageType.blindListen,
        SubStageType.reviewDifficultPractice,
        SubStageType.reviewRetellSummary,
        SubStageType.reviewRetellParagraph,
      ]);
    });

    test('completed 空列表', () {
      expect(LearningStage.completed.allSubStages, isEmpty);
    });
  });
}
