import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/database/enums.dart';
import 'package:loop_back/models/learning_plan.dart';
import 'package:loop_back/models/learning_progress.dart';

void main() {
  final now = DateTime(2026, 2, 21);
  // plan 现在是静态的，永远全量（包含复述）。
  // 「跳过」由 LearningProgress.skippedSubStageKeys 承载，不再过滤 plan。
  final planOn = LearningPlan.standard();
  final planOff = LearningPlan.standard();

  /// 便捷构造 completedKeys 集合
  Set<String> keys(List<(LearningStage, SubStageType)> items) =>
      items.map((p) => '${p.$1.key}:${p.$2.key}').toSet();

  /// 「过去阶段所有 plan 内子步骤都做过」的便捷集合（默认 v2 plan）。
  ///
  /// 注意：用 plan.subStagesFor 而非 stage.allSubStages，因为后者包含 v1 ∪ v2
  /// 的展示并集；用 plan 反映「真实学习过」的子步骤集合。
  Set<String> doneUpTo(LearningStage stage) {
    final plan = LearningPlan.standard();
    final set = <String>{};
    for (final s in LearningStage.values) {
      if (s.index >= stage.index) break;
      for (final sub in plan.subStagesFor(s)) {
        set.add('${s.key}:${sub.key}');
      }
    }
    return set;
  }

  group('LearningProgress', () {
    test('初始状态 — 未开始（v2 入口为逐句精听）', () {
      // v2 新建音频入口子步骤为精听；空 planVersions → 默认 v2。
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentSubStage: SubStageType.intensiveListen,
        updatedAt: now,
      );
      const noCompletions = <String>{};

      expect(progress.isStarted, false);
      expect(progress.isCompleted, false);
      expect(progress.progressPercent(planOn, noCompletions), 0.0);
      expect(progress.completedFirstStudySteps(planOn, noCompletions), 0);
      expect(progress.completedReviewStages, 0);
    });

    test('canSkipCurrentSubStage — v2 仅首次学习入口（精听）不可跳过', () {
      // v2 首次学习精听（入口）→ 不可跳过
      expect(
        LearningProgress(
          audioItemId: 'a1',
          currentSubStage: SubStageType.intensiveListen,
          updatedAt: now,
        ).canSkipCurrentSubStage,
        false,
      );
      // v2 首次学习其余子步骤（含后置盲听）→ 可跳过
      for (final sub in const [
        SubStageType.listenAndRepeat,
        SubStageType.blindListen,
        SubStageType.retell,
      ]) {
        expect(
          LearningProgress(
            audioItemId: 'a1',
            currentStage: LearningStage.firstLearn,
            currentSubStage: sub,
            updatedAt: now,
          ).canSkipCurrentSubStage,
          true,
          reason: 'firstLearn(v2):$sub 应可跳过',
        );
      }
      // 复习阶段的盲听 → 可跳过
      expect(
        LearningProgress(
          audioItemId: 'a1',
          currentStage: LearningStage.review1,
          currentSubStage: SubStageType.blindListen,
          updatedAt: now,
        ).canSkipCurrentSubStage,
        true,
      );
    });

    test('canSkipCurrentSubStage — v1 仍是首次学习盲听不可跳过', () {
      const v1 = {LearningStage.firstLearn: 1};
      // v1 首次学习盲听（入口）→ 不可跳过
      expect(
        LearningProgress(
          audioItemId: 'a1',
          currentSubStage: SubStageType.blindListen,
          planVersionsByStage: v1,
          updatedAt: now,
        ).canSkipCurrentSubStage,
        false,
      );
      // v1 首次学习精听 → 可跳过
      expect(
        LearningProgress(
          audioItemId: 'a1',
          currentSubStage: SubStageType.intensiveListen,
          planVersionsByStage: v1,
          updatedAt: now,
        ).canSkipCurrentSubStage,
        true,
      );
    });

    test('首次学习第 2 个子步骤进行中（v2 已完成精听，现在跟读）', () {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.listenAndRepeat,
        updatedAt: now,
      );
      final completed = keys([
        (LearningStage.firstLearn, SubStageType.intensiveListen),
      ]);

      expect(progress.isStarted, true);
      expect(progress.isCompleted, false);
      // plan v2 总 23 步（firstLearn:4 + review0:2 + review1:2 + review2/4/7/14:3*4 + review28:3）；已完成 1
      expect(
        progress.progressPercent(planOn, completed),
        closeTo(1 / 23, 0.001),
      );
      expect(progress.completedFirstStudySteps(planOn, completed), 1);
    });

    test('首次学习全部完成，进入 review0', () {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review0,
        currentSubStage: SubStageType.reviewDifficultPractice,
        firstLearnCompletedAt: now,
        updatedAt: now,
      );
      final completed = doneUpTo(LearningStage.review0); // firstLearn 全部 4 步

      expect(progress.isStarted, true);
      expect(
        progress.progressPercent(planOn, completed),
        closeTo(4 / 23, 0.001),
      );
      expect(progress.completedFirstStudySteps(planOn, completed), 4);
    });

    test('review2 第 2 个子步骤进行中', () {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review2,
        currentSubStage: SubStageType.reviewDifficultPractice,
        firstLearnCompletedAt: now,
        updatedAt: now,
      );
      final completed = doneUpTo(LearningStage.review2)
        ..add('${LearningStage.review2.key}:${SubStageType.blindListen.key}');
      // 完成了：4(firstLearn) + 2(review0) + 2(review1) + 1(review2.blind) = 9
      expect(
        progress.progressPercent(planOn, completed),
        closeTo(9 / 23, 0.001),
      );
      expect(progress.completedFirstStudySteps(planOn, completed), 4);
      expect(progress.completedReviewStages, 2);
    });

    test('已完成状态（isCompleted 始终返回 1.0）', () {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.completed,
        currentSubStage: SubStageType.blindListen,
        firstLearnCompletedAt: now,
        updatedAt: now,
      );
      const anyCompleted = <String>{};

      expect(progress.isCompleted, true);
      expect(progress.progressPercent(planOn, anyCompleted), 1.0);
    });

    test('isStageCompleted 正确判断', () {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review2,
        currentSubStage: SubStageType.reviewDifficultPractice,
        updatedAt: now,
      );

      expect(progress.isStageCompleted(LearningStage.firstLearn), true);
      expect(progress.isStageCompleted(LearningStage.review0), true);
      expect(progress.isStageCompleted(LearningStage.review1), true);
      expect(progress.isStageCompleted(LearningStage.review2), false);
      expect(progress.isStageCompleted(LearningStage.review4), false);
    });

    test('isSubStageCompleted 直接查 completedKeys（真实历史）', () {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.listenAndRepeat,
        updatedAt: now,
      );
      final completed = keys([
        (LearningStage.firstLearn, SubStageType.blindListen),
        (LearningStage.firstLearn, SubStageType.intensiveListen),
      ]);

      expect(
        progress.isSubStageCompleted(
          LearningStage.firstLearn,
          SubStageType.blindListen,
          completed,
        ),
        true,
      );
      expect(
        progress.isSubStageCompleted(
          LearningStage.firstLearn,
          SubStageType.intensiveListen,
          completed,
        ),
        true,
      );
      expect(
        progress.isSubStageCompleted(
          LearningStage.firstLearn,
          SubStageType.listenAndRepeat,
          completed,
        ),
        false,
      );
      expect(
        progress.isSubStageCompleted(
          LearningStage.firstLearn,
          SubStageType.retell,
          completed,
        ),
        false,
      );
    });

    test(
      'isSubStageCompleted — 跳过的子步骤不在 completedKeys → false（bug 2 关键回归）',
      () {
        // 模拟：关闭复述完成 review0 难句补练 → currentStage 推进到 review1
        // 注意 completedKeys 中只有 review0.reviewDifficultPractice，无 retell
        final progress = LearningProgress(
          audioItemId: 'audio-1',
          currentStage: LearningStage.review1,
          currentSubStage: SubStageType.blindListen,
          updatedAt: now,
        );
        final completed = keys([
          ...LearningStage.firstLearn.allSubStages.map(
            (s) => (LearningStage.firstLearn, s),
          ),
          (LearningStage.review0, SubStageType.reviewDifficultPractice),
        ]);

        // review0 的 retell 用户从未做过 → completed=false 即使阶段已过 +
        // 现在 plan 包含它（重新打开复述后的情景）
        expect(
          progress.isSubStageCompleted(
            LearningStage.review0,
            SubStageType.reviewRetellParagraph,
            completed,
          ),
          isFalse,
          reason: '跳过的复述（无完成记录）不应被视作完成',
        );
        // 真做过的非复述步骤 → completed=true
        expect(
          progress.isSubStageCompleted(
            LearningStage.review0,
            SubStageType.reviewDifficultPractice,
            completed,
          ),
          isTrue,
        );
      },
    );

    test('isSubStageCompleted — 已完成的 retell 即使 plan 不含也保留（bug 3 关键回归）', () {
      // 模拟：开启复述完成 firstLearn 全部 4 步，然后关闭复述
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review0,
        currentSubStage: SubStageType.reviewDifficultPractice,
        updatedAt: now,
      );
      final completed = keys(
        LearningStage.firstLearn.allSubStages
            .map((s) => (LearningStage.firstLearn, s))
            .toList(),
      );

      // retell 在 completedKeys → completed=true（不论当前 plan 是否包含）
      expect(
        progress.isSubStageCompleted(
          LearningStage.firstLearn,
          SubStageType.retell,
          completed,
        ),
        isTrue,
        reason: '已做过的复述应该保持 completed 状态',
      );
    });

    test('isCurrentStage 正确判断', () {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review7,
        currentSubStage: SubStageType.reviewDifficultPractice,
        updatedAt: now,
      );

      expect(progress.isCurrentStage(LearningStage.review4), false);
      expect(progress.isCurrentStage(LearningStage.review7), true);
      expect(progress.isCurrentStage(LearningStage.review14), false);
    });

    test('isCurrentSubStage 正确判断', () {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.listenAndRepeat,
        updatedAt: now,
      );

      expect(
        progress.isCurrentSubStage(
          LearningStage.firstLearn,
          SubStageType.intensiveListen,
        ),
        false,
      );
      expect(
        progress.isCurrentSubStage(
          LearningStage.firstLearn,
          SubStageType.listenAndRepeat,
        ),
        true,
      );
      expect(
        progress.isCurrentSubStage(
          LearningStage.firstLearn,
          SubStageType.retell,
        ),
        false,
      );
    });

    test('copyWith 正确创建副本', () {
      final original = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.blindListen,
        difficulty: DifficultyLevel.medium,
        updatedAt: now,
      );

      final updated = original.copyWith(
        currentSubStage: SubStageType.retell,
        difficulty: DifficultyLevel.hard,
        totalStudyDurationMs: 5000,
        lastStageCompletedAt: now,
        currentStageStartedAt: now,
      );

      expect(updated.audioItemId, 'audio-1');
      expect(updated.currentStage, LearningStage.firstLearn);
      expect(updated.currentSubStage, SubStageType.retell);
      expect(updated.difficulty, DifficultyLevel.hard);
      expect(updated.totalStudyDurationMs, 5000);
      expect(updated.lastStageCompletedAt, now);
      expect(updated.currentStageStartedAt, now);
    });

    test('totalSubStages 动态计算正确', () {
      // firstLearn:4 + review0:3 + review1/2/4/7/14: 5*3 + review28:4 (v1 ∪ v2 4 项) = 26
      // 注：completed.allSubStages = []，对 totalSubStages 无贡献
      expect(LearningProgress.totalSubStages, 26);
    });

    test('isPaused 默认 false', () {
      final progress = LearningProgress(audioItemId: 'a1', updatedAt: now);
      expect(progress.isPaused, false);
    });

    test('copyWith 可切换 isPaused 而不影响其他字段', () {
      final progress = LearningProgress(
        audioItemId: 'a1',
        currentStage: LearningStage.review2,
        currentSubStage: SubStageType.reviewDifficultPractice,
        updatedAt: now,
      );
      final paused = progress.copyWith(isPaused: true);
      final resumed = paused.copyWith(isPaused: false);

      expect(paused.isPaused, true);
      expect(paused.currentStage, LearningStage.review2);
      expect(resumed.isPaused, false);
      expect(resumed.currentStage, LearningStage.review2);
    });
  });

  group('progressPercent(plan) / completedFirstStudySteps(plan)', () {
    test('firstLearn 在 listenAndRepeat → 已完成 2 步', () {
      final progress = LearningProgress(
        audioItemId: 'a1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.listenAndRepeat,
        updatedAt: now,
      );
      final completed = keys([
        (LearningStage.firstLearn, SubStageType.blindListen),
        (LearningStage.firstLearn, SubStageType.intensiveListen),
      ]);
      expect(progress.completedFirstStudySteps(planOff, completed), 2);
    });

    test('completed 阶段 progressPercent 返回 1.0', () {
      final progress = LearningProgress(
        audioItemId: 'a1',
        currentStage: LearningStage.completed,
        updatedAt: now,
      );
      expect(progress.progressPercent(planOff, const {}), 1.0);
    });

    test('已完成的 retell 计入分子', () {
      final progress = LearningProgress(
        audioItemId: 'a1',
        currentStage: LearningStage.review0,
        currentSubStage: SubStageType.reviewDifficultPractice,
        updatedAt: now,
      );
      final completed = keys(
        LearningStage.firstLearn.allSubStages
            .map((s) => (LearningStage.firstLearn, s))
            .toList(),
      );

      final off = progress.progressPercent(planOff, completed);
      expect(off, greaterThan(0));
      expect(progress.completedFirstStudySteps(planOff, completed), 4);
    });

    test('跳过的子步骤计入分子+分母（纯跳过场景能到 100%）', () {
      // 模拟所有子步骤都被跳过的极端场景
      final allKeys = <String>{};
      for (final s in LearningStage.values) {
        for (final sub in s.allSubStages) {
          allKeys.add('${s.key}:${sub.key}');
        }
      }
      final progress = LearningProgress(
        audioItemId: 'a1',
        currentStage: LearningStage.review28,
        currentSubStage: SubStageType.reviewRetellSummary,
        skippedSubStageKeys: allKeys,
        updatedAt: now,
      );
      // 没有 completion 但所有都跳过 → 分母 = 分子 = allKeys.length，比例 = 1.0
      expect(progress.progressPercent(planOff, const {}), 1.0);
    });

    test('isSubStageSkipped 正确查询 skippedSubStageKeys', () {
      final progress = LearningProgress(
        audioItemId: 'a1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.retell,
        skippedSubStageKeys: const {'firstLearn:retell'},
        updatedAt: now,
      );
      expect(
        progress.isSubStageSkipped(
          LearningStage.firstLearn,
          SubStageType.retell,
        ),
        isTrue,
      );
      expect(
        progress.isSubStageSkipped(
          LearningStage.firstLearn,
          SubStageType.blindListen,
        ),
        isFalse,
      );
    });
  });

  group('nextReviewAt / isReviewReadyAt / isReviewLockedAt', () {
    test('首次学习阶段 — nextReviewAt 为 null，isReviewReadyAt 为 true', () {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.firstLearn,
        updatedAt: now,
      );

      expect(progress.nextReviewAt, isNull);
      expect(progress.isReviewReadyAt(DateTime(2026, 2, 21, 10, 0)), true);
    });

    test('review0 — intervalHours=6，nextReviewAt 正确计算', () {
      final completedAt = DateTime(2026, 2, 21, 10, 0);
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review0,
        currentSubStage: SubStageType.blindListen,
        lastStageCompletedAt: completedAt,
        updatedAt: completedAt,
      );

      // review0 的 intervalHours 是 6
      final expectedReviewAt = completedAt.add(const Duration(hours: 6));
      expect(progress.nextReviewAt, expectedReviewAt);
    });

    test('review1 — 有 lastStageCompletedAt 时按增量 18h 计算', () {
      final completedAt = DateTime(2026, 2, 20, 10, 0);
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review1,
        currentSubStage: SubStageType.blindListen,
        lastStageCompletedAt: completedAt,
        updatedAt: now,
      );

      // review1 的 intervalHours = 18（1天 - 6小时）
      final expectedReviewAt = completedAt.add(const Duration(hours: 18));
      expect(progress.nextReviewAt, expectedReviewAt);
    });

    test('review1 — 无 lastStageCompletedAt 时 nextReviewAt 为 null', () {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review1,
        currentSubStage: SubStageType.blindListen,
        updatedAt: now,
      );

      expect(progress.nextReviewAt, isNull);
      expect(progress.isReviewReadyAt(DateTime(2026, 2, 21, 10, 0)), true);
    });

    test('review7 — 正确计算 72 小时间隔', () {
      final completedAt = DateTime(2026, 2, 14);
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review7,
        currentSubStage: SubStageType.blindListen,
        lastStageCompletedAt: completedAt,
        updatedAt: now,
      );

      final expectedReviewAt = completedAt.add(const Duration(hours: 72));
      expect(progress.nextReviewAt, expectedReviewAt);
    });

    test('晚完成某轮后，后续轮次按上一轮完成时间顺延', () {
      final review1CompletedAt = DateTime(2026, 2, 20, 22, 0);
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review2,
        currentSubStage: SubStageType.blindListen,
        lastStageCompletedAt: review1CompletedAt,
        updatedAt: now,
      );

      expect(
        progress.nextReviewAt,
        review1CompletedAt.add(const Duration(hours: 24)),
      );
    });

    test('review0 解锁边界：未到时间时锁定、边界时刻解锁、超过边界解锁', () {
      final completedAt = DateTime(2026, 2, 21, 10, 0);
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review0,
        currentSubStage: SubStageType.blindListen,
        lastStageCompletedAt: completedAt,
        updatedAt: completedAt,
      );

      final reviewAt = completedAt.add(const Duration(hours: 6));
      final before = reviewAt.subtract(const Duration(seconds: 1));
      final at = reviewAt;
      final after = reviewAt.add(const Duration(seconds: 1));

      expect(progress.isInReviewStage, true);
      expect(progress.isReviewReadyAt(before), false);
      expect(progress.isReviewLockedAt(before), true);
      expect(progress.isReviewReadyAt(at), true);
      expect(progress.isReviewLockedAt(at), false);
      expect(progress.isReviewReadyAt(after), true);
      expect(progress.isReviewLockedAt(after), false);
    });

    test('review1 解锁边界：未到时间时锁定、边界时刻解锁、超过边界解锁', () {
      final completedAt = DateTime(2026, 2, 21, 10, 0);
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review1,
        currentSubStage: SubStageType.blindListen,
        lastStageCompletedAt: completedAt,
        updatedAt: completedAt,
      );

      final reviewAt = completedAt.add(const Duration(hours: 18));
      final before = reviewAt.subtract(const Duration(seconds: 1));
      final at = reviewAt;
      final after = reviewAt.add(const Duration(seconds: 1));

      expect(progress.isReviewReadyAt(before), false);
      expect(progress.isReviewLockedAt(before), true);
      expect(progress.isReviewReadyAt(at), true);
      expect(progress.isReviewLockedAt(at), false);
      expect(progress.isReviewReadyAt(after), true);
      expect(progress.isReviewLockedAt(after), false);
    });

    test('手动解锁 — nextReviewAt 返回解锁时刻，锁定判定立即解除', () {
      final completedAt = DateTime(2026, 2, 21, 10, 0);
      final unlockAt = DateTime(2026, 2, 21, 12, 0); // 原定 16:00 解锁，提前到 12:00
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review0,
        currentSubStage: SubStageType.blindListen,
        lastStageCompletedAt: completedAt,
        manualUnlockAt: unlockAt,
        updatedAt: unlockAt,
      );

      expect(progress.nextReviewAt, unlockAt);
      expect(progress.isReviewReadyAt(unlockAt), true);
      expect(progress.isReviewLockedAt(unlockAt), false);
    });

    test('手动解锁 — now 早于 manualUnlockAt（时光机偏差）仍视为已解锁', () {
      final completedAt = DateTime(2026, 2, 21, 10, 0);
      final unlockAt = DateTime(2026, 2, 21, 12, 0);
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review1,
        currentSubStage: SubStageType.blindListen,
        lastStageCompletedAt: completedAt,
        manualUnlockAt: unlockAt,
        updatedAt: unlockAt,
      );

      // 时光机可能让业务层的 now 早于真实持久化的解锁时刻，
      // isReviewReadyAt 对非空 manualUnlockAt 无条件短路。
      final debugNow = DateTime(2026, 2, 21, 11, 0);
      expect(progress.isReviewReadyAt(debugNow), true);
      expect(progress.isReviewLockedAt(debugNow), false);
    });

    test('手动解锁 — 逾期窗口从解锁时刻起算', () {
      final completedAt = DateTime(2026, 2, 21, 10, 0);
      final unlockAt = DateTime(2026, 2, 21, 12, 0);
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review0,
        currentSubStage: SubStageType.reviewDifficultPractice,
        lastStageCompletedAt: completedAt,
        manualUnlockAt: unlockAt,
        updatedAt: unlockAt,
      );

      // review0 窗口 6h：解锁后窗口 = 解锁时刻 + 6h
      expect(
        progress.reviewWindowEndAt,
        unlockAt.add(const Duration(hours: 6)),
      );
    });

    test('copyWith — manualUnlockAt 默认保留，clearManualUnlockAt 清空', () {
      final unlockAt = DateTime(2026, 2, 21, 12, 0);
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review0,
        currentSubStage: SubStageType.blindListen,
        lastStageCompletedAt: DateTime(2026, 2, 21, 10, 0),
        manualUnlockAt: unlockAt,
        updatedAt: unlockAt,
      );

      // 默认保留
      final kept = progress.copyWith(totalStudyDurationMs: 1000);
      expect(kept.manualUnlockAt, unlockAt);

      // 显式清空（跨 stage 推进时使用）
      final cleared = progress.copyWith(clearManualUnlockAt: true);
      expect(cleared.manualUnlockAt, isNull);
      // 清空后恢复原时间锁
      expect(
        cleared.nextReviewAt,
        DateTime(2026, 2, 21, 10, 0).add(const Duration(hours: 6)),
      );
    });

    test('首次学习阶段 isReviewLockedAt=false', () {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.intensiveListen,
        updatedAt: now,
      );

      expect(progress.isInReviewStage, false);
      expect(progress.isReviewLockedAt(DateTime(2026, 2, 21, 10, 0)), false);
    });

    test('review0 逾期窗口：解锁后 6 小时内不算逾期，超过才逾期', () {
      final completedAt = DateTime(2026, 2, 21, 10, 0);
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review0,
        currentSubStage: SubStageType.reviewDifficultPractice,
        lastStageCompletedAt: completedAt,
        updatedAt: completedAt,
      );

      final reviewAt = completedAt.add(const Duration(hours: 6));
      final windowEnd = reviewAt.add(const Duration(hours: 6));
      expect(progress.reviewWindowDuration, const Duration(hours: 6));
      expect(progress.reviewWindowEndAt, windowEnd);

      final beforeWindowEnd = windowEnd.subtract(const Duration(seconds: 1));
      expect(progress.isReviewOverdueAt(beforeWindowEnd), false);
      expect(progress.isReviewOverdueAt(windowEnd), false);

      final afterWindowEnd = windowEnd.add(const Duration(seconds: 1));
      expect(progress.isReviewOverdueAt(afterWindowEnd), true);
      expect(
        progress.overdueDurationAt(afterWindowEnd),
        const Duration(seconds: 1),
      );
    });

    test('review1 逾期窗口：解锁后 24 小时内不算逾期，超过才逾期', () {
      final completedAt = DateTime(2026, 2, 21, 10, 0);
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.review1,
        currentSubStage: SubStageType.blindListen,
        lastStageCompletedAt: completedAt,
        updatedAt: completedAt,
      );

      final reviewAt = completedAt.add(const Duration(hours: 18));
      final windowEnd = reviewAt.add(const Duration(hours: 24));
      expect(progress.reviewWindowDuration, const Duration(hours: 24));
      expect(progress.reviewWindowEndAt, windowEnd);

      final beforeWindowEnd = windowEnd.subtract(const Duration(seconds: 1));
      expect(progress.isReviewOverdueAt(beforeWindowEnd), false);
      expect(progress.isReviewOverdueAt(windowEnd), false);

      final afterWindowEnd = windowEnd.add(const Duration(seconds: 1));
      expect(progress.isReviewOverdueAt(afterWindowEnd), true);
      expect(
        progress.overdueDurationAt(afterWindowEnd),
        const Duration(seconds: 1),
      );
    });

    test('非复习阶段无逾期窗口，始终不逾期', () {
      final progress = LearningProgress(
        audioItemId: 'audio-1',
        currentStage: LearningStage.firstLearn,
        currentSubStage: SubStageType.listenAndRepeat,
        updatedAt: now,
      );

      expect(progress.reviewWindowDuration, isNull);
      expect(progress.reviewWindowEndAt, isNull);
      expect(progress.isReviewOverdueAt(DateTime(2026, 2, 21, 12, 0)), false);
      expect(progress.overdueDurationAt(DateTime(2026, 2, 21, 12, 0)), isNull);
    });
  });

  group('LearningStage', () {
    test('subStageCount 正确', () {
      expect(LearningStage.firstLearn.subStageCount, 4);
      // review0 / review28 返回 v1 ∪ v2 并集；真实 plan 由 LearningPlan 派生为 2/3 项。
      expect(LearningStage.review0.subStageCount, 3);
      expect(LearningStage.review1.subStageCount, 3);
      expect(LearningStage.review28.subStageCount, 4);
      expect(LearningStage.completed.subStageCount, 0);
    });

    test('总子步骤数 = totalSubStages', () {
      int total = 0;
      for (final stage in LearningStage.values) {
        total += stage.subStageCount;
      }
      expect(total, LearningProgress.totalSubStages);
    });

    test('fromKey 正确转换', () {
      expect(LearningStage.fromKey('firstLearn'), LearningStage.firstLearn);
      expect(LearningStage.fromKey('review7'), LearningStage.review7);
      expect(LearningStage.fromKey('completed'), LearningStage.completed);
      // 无效键返回 firstLearn
      expect(LearningStage.fromKey('invalid'), LearningStage.firstLearn);
    });

    test('label 不为空', () {
      for (final stage in LearningStage.values) {
        expect(stage.label.isNotEmpty, true);
      }
    });

    test('subStages 列表内容正确', () {
      expect(LearningStage.firstLearn.allSubStages, [
        SubStageType.intensiveListen,
        SubStageType.listenAndRepeat,
        SubStageType.blindListen,
        SubStageType.retell,
      ]);
      // v1 ∪ v2 并集（真实 plan 由 LearningPlan 按 planVersionsByStage 派生）
      expect(LearningStage.review0.allSubStages, [
        SubStageType.reviewDifficultPractice,
        SubStageType.blindListen,
        SubStageType.reviewRetellParagraph,
      ]);
      expect(LearningStage.review1.allSubStages, [
        SubStageType.blindListen,
        SubStageType.reviewDifficultPractice,
        SubStageType.reviewRetellParagraph,
      ]);
      expect(LearningStage.review28.allSubStages, [
        SubStageType.blindListen,
        SubStageType.reviewDifficultPractice,
        SubStageType.reviewRetellSummary,
        SubStageType.reviewRetellParagraph,
      ]);
      expect(LearningStage.completed.allSubStages, isEmpty);
    });
  });

  group('SubStageType', () {
    test('fromKey 正确转换', () {
      expect(SubStageType.fromKey('blindListen'), SubStageType.blindListen);
      expect(
        SubStageType.fromKey('listenAndRepeat'),
        SubStageType.listenAndRepeat,
      );
      expect(SubStageType.fromKey('retell'), SubStageType.retell);
      expect(
        SubStageType.fromKey('reviewDifficultPractice'),
        SubStageType.reviewDifficultPractice,
      );
      // 无效键返回 blindListen
      expect(SubStageType.fromKey('invalid'), SubStageType.blindListen);
    });
  });

  group('DifficultyLevel', () {
    test('fromValue 正确转换（5 档）', () {
      expect(DifficultyLevel.fromValue(0), DifficultyLevel.veryEasy);
      expect(DifficultyLevel.fromValue(1), DifficultyLevel.easy);
      expect(DifficultyLevel.fromValue(2), DifficultyLevel.medium);
      expect(DifficultyLevel.fromValue(3), DifficultyLevel.hard);
      expect(DifficultyLevel.fromValue(4), DifficultyLevel.veryHard);
      // 无效值返回 medium
      expect(DifficultyLevel.fromValue(99), DifficultyLevel.medium);
    });

    test('label 不为空', () {
      for (final level in DifficultyLevel.values) {
        expect(level.label.isNotEmpty, true);
      }
    });

    test('共 5 个难度等级', () {
      expect(DifficultyLevel.values.length, 5);
    });
  });
}
