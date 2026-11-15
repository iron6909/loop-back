/// 点「开始学习」时该启动哪个流程。
///
/// 计划页的启动入口原先是一条 if-else 链（复习未解锁 → 复习分发 → 四个首次学习
/// 子步骤 → 兜底随心听），判断与分支散在 UI 里。这里把「先判断、再分派」收成纯函数，
/// 页面只负责按结果调用对应流程。
library;

import '../database/enums.dart';
import '../models/learning_progress.dart';

/// 启动动作。
enum LearningStartAction {
  /// 复习未到时间：什么都不做（底栏按钮此时也是禁用态）。
  blocked,

  /// 进入复习轮次的子步骤分发（见 `planReviewLaunch`）。
  reviewSubStage,

  blindListen,
  intensiveListen,
  listenAndRepeat,
  retell,

  /// 其他子步骤：直接打开随心听播放器。
  freePlay,
}

/// 决定本次「开始学习」启动哪个流程。
///
/// [now] 由调用方注入，复习窗口判断因此可测；顺序与原实现一致：
/// 先看复习是否未到时间，再看是否处于复习阶段，最后按首次学习子步骤分派。
LearningStartAction planLearningStart({
  required LearningProgress progress,
  required DateTime now,
}) {
  if (progress.isReviewLockedAt(now)) return LearningStartAction.blocked;
  if (progress.isInReviewStage) return LearningStartAction.reviewSubStage;

  return switch (progress.currentSubStage) {
    SubStageType.blindListen => LearningStartAction.blindListen,
    SubStageType.intensiveListen => LearningStartAction.intensiveListen,
    SubStageType.listenAndRepeat => LearningStartAction.listenAndRepeat,
    SubStageType.retell => LearningStartAction.retell,
    _ => LearningStartAction.freePlay,
  };
}
