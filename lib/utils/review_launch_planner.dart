/// 复习子步骤的启动方式。
///
/// 计划页有两个入口会启动复习子步骤：用户主动点「开始」（[autoAdvance] 为 false），
/// 以及上一步完成后自动推进（[autoAdvance] 为 true）。两处此前各写一份 switch，
/// 差别只体现在注释里；这里把差异收成一个参数，规则只有一份。
library;

import '../database/enums.dart';

/// 复习子步骤要打开哪个入口。
enum ReviewLaunch {
  /// 段落盲听：自带段落选择弹窗，阶段名与预估时长直接显示在弹窗上。
  blindListen,

  /// 段落复述：自带时长选择弹窗。
  retellParagraph,

  /// 全文复述：自动推进时直接进入（用户主动点击时先看复习简报）。
  retellSummary,

  /// 先展示复习简报再进入：难句补练等需要先确认遍数/停顿的子步骤。
  briefing,

  /// 自动推进落到的子步骤不自动进入，回到计划页让用户重新选择。
  none,
}

/// 决定复习子步骤怎么进入。
///
/// 自动推进只进入自带选择弹窗的页面（盲听 / 段落复述 / 全文复述），其余回到计划页；
/// 用户主动点击则先看复习简报，所以难句补练从计划页进入会看到简报，自动推进时不会。
ReviewLaunch planReviewLaunch(
  SubStageType subStage, {
  required bool autoAdvance,
}) {
  switch (subStage) {
    case SubStageType.blindListen:
      return ReviewLaunch.blindListen;
    case SubStageType.reviewRetellParagraph:
      return ReviewLaunch.retellParagraph;
    case SubStageType.reviewRetellSummary:
      return autoAdvance ? ReviewLaunch.retellSummary : ReviewLaunch.briefing;
    default:
      return autoAdvance ? ReviewLaunch.none : ReviewLaunch.briefing;
  }
}
