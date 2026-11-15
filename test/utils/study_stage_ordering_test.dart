import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/database/enums.dart';
import 'package:loop_back/models/learning_plan.dart';
import 'package:loop_back/utils/study_stage_ordering.dart';

void main() {
  group('orderedSubStagesForDisplay', () {
    test('没有历史外延项时按当前 plan 顺序返回', () {
      final plan = LearningPlan.standard(
        stagePlanVersions: {LearningStage.review28: 2},
      );

      expect(
        orderedSubStagesForDisplay(
          plan: plan,
          stage: LearningStage.review28,
          completedKeys: const {},
          skippedKeys: const {},
        ),
        plan.subStagesFor(LearningStage.review28),
      );
    });

    test('评审 v1 完成、v2 已移除的子步骤仍排在末尾显示', () {
      // review28 从 v1 升到 v2 后不再包含 reviewRetellSummary，
      // 但走过 v1 的用户仍需看到它已完成。
      final plan = LearningPlan.standard(
        stagePlanVersions: {LearningStage.review28: 2},
      );
      final completedKey =
          '${LearningStage.review28.key}:${SubStageType.reviewRetellSummary.key}';

      final ordered = orderedSubStagesForDisplay(
        plan: plan,
        stage: LearningStage.review28,
        completedKeys: {completedKey},
        skippedKeys: const {},
      );

      expect(ordered.last, SubStageType.reviewRetellSummary);
      expect(ordered.take(ordered.length - 1), plan.subStagesFor(
        LearningStage.review28,
      ));
    });

    test('跳过过的历史子步骤同样保留，未完成也未跳过的不显示', () {
      final plan = LearningPlan.standard(
        stagePlanVersions: {LearningStage.review28: 2},
      );
      final skippedKey =
          '${LearningStage.review28.key}:${SubStageType.reviewRetellSummary.key}';

      expect(
        orderedSubStagesForDisplay(
          plan: plan,
          stage: LearningStage.review28,
          completedKeys: const {},
          skippedKeys: {skippedKey},
        ),
        contains(SubStageType.reviewRetellSummary),
      );
      expect(
        orderedSubStagesForDisplay(
          plan: plan,
          stage: LearningStage.review28,
          completedKeys: const {},
          skippedKeys: const {},
        ),
        isNot(contains(SubStageType.reviewRetellSummary)),
      );
    });

    test('历史外延项按键格式匹配阶段，不跨阶段串味', () {
      final plan = LearningPlan.standard(
        stagePlanVersions: {LearningStage.review28: 2},
      );
      final otherStageKey =
          '${LearningStage.review14.key}:${SubStageType.reviewRetellSummary.key}';

      expect(
        orderedSubStagesForDisplay(
          plan: plan,
          stage: LearningStage.review28,
          completedKeys: {otherStageKey},
          skippedKeys: const {},
        ),
        isNot(contains(SubStageType.reviewRetellSummary)),
      );
    });
  });
}
