/// 学习计划阶段子步骤的展示顺序。
///
/// 展示顺序 = 当前 plan 顺序 + 历史外延项。历史外延项指「已完成或已跳过、但已不在
/// 当前 plan 内」的子步骤（例如 review28 从 v1 升到 v2 后被移除的 reviewRetellSummary），
/// 保留它们才能让老用户看到自己的历史进度。
library;

import '../database/enums.dart';
import '../models/learning_plan.dart';

/// 返回该阶段要展示的子步骤顺序。
///
/// [completedKeys] / [skippedKeys] 的键格式为 `<stage.key>:<subStage.key>`。
List<SubStageType> orderedSubStagesForDisplay({
  required LearningPlan plan,
  required LearningStage stage,
  required Set<String> completedKeys,
  required Set<String> skippedKeys,
}) {
  final planned = plan.subStagesFor(stage);
  final extras = stage.allSubStages
      .where((subStage) {
        if (planned.contains(subStage)) return false;
        final key = '${stage.key}:${subStage.key}';
        return completedKeys.contains(key) || skippedKeys.contains(key);
      })
      .toList(growable: false);
  return [...planned, ...extras];
}
