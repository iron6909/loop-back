/// LearningPlan 值对象测试
///
/// plan 现在按 audio 持久化的 `stagePlanVersions` map 派生（snapshot-per-entity）。
/// 每个 LearningStage 显式版本号，未指定时回退到 `kLatestPlanVersions`。
///
/// 「不做某类子阶段」的语义通过 `LearningProgress.skippedSubStageKeys` 承载。
library;

import 'package:loop_back/database/enums.dart';
import 'package:loop_back/models/learning_plan.dart';
import 'package:flutter_test/flutter_test.dart';

const _mid = [
  LearningStage.review2,
  LearningStage.review4,
  LearningStage.review7,
  LearningStage.review14,
];

void main() {
  group('kLatestPlanVersions（dense baseline）', () {
    test('覆盖所有带 plan 的 LearningStage（除 completed 外）', () {
      for (final s in LearningStage.values) {
        if (s == LearningStage.completed) {
          // completed 是毕业终态，无 plan，不参与版本化
          expect(
            kLatestPlanVersions.containsKey(s),
            isFalse,
            reason: 'completed 不应在 map 中',
          );
          continue;
        }
        expect(kLatestPlanVersions.containsKey(s), isTrue, reason: '缺 $s');
      }
    });

    test('当前版本快照', () {
      // 当前各 stage 的最新版本（这是 ground truth；改了请同步更新本期望）
      expect(kLatestPlanVersions[LearningStage.firstLearn], 2);
      expect(kLatestPlanVersions[LearningStage.review0], 2);
      expect(kLatestPlanVersions[LearningStage.review1], 2);
      expect(kLatestPlanVersions[LearningStage.review2], 2);
      expect(kLatestPlanVersions[LearningStage.review4], 2);
      expect(kLatestPlanVersions[LearningStage.review7], 2);
      expect(kLatestPlanVersions[LearningStage.review14], 2);
      expect(kLatestPlanVersions[LearningStage.review28], 2);
    });
  });

  group('LearningPlan.standard 默认（空 map → kLatestPlanVersions 全 v2）', () {
    final plan = LearningPlan.standard();

    test('firstLearn v2 = [精听, 跟读, 盲听, 段落复述]', () {
      expect(plan.subStagesFor(LearningStage.firstLearn), [
        SubStageType.intensiveListen,
        SubStageType.listenAndRepeat,
        SubStageType.blindListen,
        SubStageType.retell,
      ]);
    });

    test('firstLearn v1 = [盲听, 精听, 跟读, 段落复述]', () {
      final v1 = LearningPlan.standard(
        stagePlanVersions: const {LearningStage.firstLearn: 1},
      );
      expect(v1.subStagesFor(LearningStage.firstLearn), [
        SubStageType.blindListen,
        SubStageType.intensiveListen,
        SubStageType.listenAndRepeat,
        SubStageType.retell,
      ]);
    });

    test('review0 v2 = [难句补练, 全文盲听]', () {
      expect(plan.subStagesFor(LearningStage.review0), [
        SubStageType.reviewDifficultPractice,
        SubStageType.blindListen,
      ]);
    });

    test('review1 v2 = [难句补练, 全文盲听]（去段落复述）', () {
      expect(plan.subStagesFor(LearningStage.review1), [
        SubStageType.reviewDifficultPractice,
        SubStageType.blindListen,
      ]);
    });

    test('review2/4/7/14 v2 = [难句补练, 全文盲听, 段落复述]（顺序新）', () {
      for (final s in _mid) {
        expect(plan.subStagesFor(s), [
          SubStageType.reviewDifficultPractice,
          SubStageType.blindListen,
          SubStageType.reviewRetellParagraph,
        ], reason: 'stage=$s');
      }
    });

    test(
      'review28 v2 = [难句补练, 全文盲听, 段落复述]（reviewRetellSummary → Paragraph）',
      () {
        expect(plan.subStagesFor(LearningStage.review28), [
          SubStageType.reviewDifficultPractice,
          SubStageType.blindListen,
          SubStageType.reviewRetellParagraph,
        ]);
      },
    );

    test('completed 空', () {
      expect(plan.subStagesFor(LearningStage.completed), isEmpty);
    });
  });

  group('LearningPlan.standard(stagePlanVersions: {...}) 单 stage 覆盖', () {
    test('review0=1 → 旧版「难句补练, 段落复述」', () {
      final plan = LearningPlan.standard(
        stagePlanVersions: const {LearningStage.review0: 1},
      );
      expect(plan.subStagesFor(LearningStage.review0), [
        SubStageType.reviewDifficultPractice,
        SubStageType.reviewRetellParagraph,
      ]);
      // 其他 stage 仍走 default
      expect(plan.subStagesFor(LearningStage.review1).length, 2);
    });

    test('review1=1 → 旧版「全文盲听, 难句补练, 段落复述」', () {
      final plan = LearningPlan.standard(
        stagePlanVersions: const {LearningStage.review1: 1},
      );
      expect(plan.subStagesFor(LearningStage.review1), [
        SubStageType.blindListen,
        SubStageType.reviewDifficultPractice,
        SubStageType.reviewRetellParagraph,
      ]);
    });

    test('review2=1 → v1 顺序', () {
      final plan = LearningPlan.standard(
        stagePlanVersions: const {LearningStage.review2: 1},
      );
      expect(plan.subStagesFor(LearningStage.review2), [
        SubStageType.blindListen,
        SubStageType.reviewDifficultPractice,
        SubStageType.reviewRetellParagraph,
      ]);
    });

    test('review28=1 → v1 用 reviewRetellSummary', () {
      final plan = LearningPlan.standard(
        stagePlanVersions: const {LearningStage.review28: 1},
      );
      expect(plan.subStagesFor(LearningStage.review28), [
        SubStageType.blindListen,
        SubStageType.reviewDifficultPractice,
        SubStageType.reviewRetellSummary,
      ]);
    });

    test('混合：review0=1, review28=1，其他 v2', () {
      final plan = LearningPlan.standard(
        stagePlanVersions: const {
          LearningStage.review0: 1,
          LearningStage.review28: 1,
        },
      );
      expect(
        plan
            .subStagesFor(LearningStage.review0)
            .contains(SubStageType.reviewRetellParagraph),
        isTrue,
      ); // v1
      expect(plan.subStagesFor(LearningStage.review1).length, 2); // v2
      expect(
        plan
            .subStagesFor(LearningStage.review28)
            .contains(SubStageType.reviewRetellSummary),
        isTrue,
      ); // v1
    });

    test('map 中显式 v2 与缺省一致', () {
      final fromExplicit = LearningPlan.standard(
        stagePlanVersions: kLatestPlanVersions,
      );
      final fromEmpty = LearningPlan.standard();
      for (final s in LearningStage.values) {
        expect(
          fromExplicit.subStagesFor(s),
          equals(fromEmpty.subStagesFor(s)),
          reason: 'stage=$s',
        );
      }
    });
  });

  group('LearningPlan API', () {
    final plan = LearningPlan.standard();

    test('includes 判定 sub 是否在 plan 内（始终 true，除非该阶段无此 sub）', () {
      expect(
        plan.includes(LearningStage.firstLearn, SubStageType.blindListen),
        isTrue,
      );
      expect(
        plan.includes(LearningStage.firstLearn, SubStageType.retell),
        isTrue,
      );
    });

    test('indexOf 返回 plan 内位置（v2: 精听0 跟读1 盲听2 复述3）', () {
      expect(
        plan.indexOf(LearningStage.firstLearn, SubStageType.listenAndRepeat),
        1,
      );
      expect(plan.indexOf(LearningStage.firstLearn, SubStageType.retell), 3);
    });

    test('totalPlannedCount = 4+2+2+3+3+3+3+3+0 = 23', () {
      // firstLearn:4 + review0:2 + review1:2 + review2/4/7/14:3*4 + review28:3 + completed:0
      expect(plan.totalPlannedCount, 4 + 2 + 2 + 3 * 4 + 3);
    });
  });

  group('LearningPlan.nextPlannedAfter', () {
    final plan = LearningPlan.standard();

    test('当前阶段 plan 中间项 → 返回下一项', () {
      final next = plan.nextPlannedAfter(
        LearningStage.firstLearn,
        SubStageType.intensiveListen,
      );
      expect(next, isNotNull);
      expect(next!.stage, LearningStage.firstLearn);
      expect(next.subStage, SubStageType.listenAndRepeat);
    });

    test('当前阶段 plan 末尾 → 返回 null（不跨阶段引导）', () {
      final next = plan.nextPlannedAfter(
        LearningStage.firstLearn,
        SubStageType.retell,
      );
      expect(next, isNull);
    });

    test('review1 v2 plan 中间项 → 全文盲听', () {
      final next = plan.nextPlannedAfter(
        LearningStage.review1,
        SubStageType.reviewDifficultPractice,
      );
      expect(next?.subStage, SubStageType.blindListen);
    });
  });
}
