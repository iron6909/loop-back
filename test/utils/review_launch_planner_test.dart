import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/database/enums.dart';
import 'package:loop_back/utils/review_launch_planner.dart';

void main() {
  group('planReviewLaunch 用户主动点击', () {
    test('盲听与段落复述直接进入，因为它们自带选择弹窗', () {
      expect(
        planReviewLaunch(SubStageType.blindListen, autoAdvance: false),
        ReviewLaunch.blindListen,
      );
      expect(
        planReviewLaunch(
          SubStageType.reviewRetellParagraph,
          autoAdvance: false,
        ),
        ReviewLaunch.retellParagraph,
      );
    });

    test('全文复述与难句补练先看复习简报', () {
      expect(
        planReviewLaunch(SubStageType.reviewRetellSummary, autoAdvance: false),
        ReviewLaunch.briefing,
      );
      expect(
        planReviewLaunch(
          SubStageType.reviewDifficultPractice,
          autoAdvance: false,
        ),
        ReviewLaunch.briefing,
      );
    });
  });

  group('planReviewLaunch 自动推进', () {
    test('只自动进入自带选择弹窗的页面', () {
      expect(
        planReviewLaunch(SubStageType.blindListen, autoAdvance: true),
        ReviewLaunch.blindListen,
      );
      expect(
        planReviewLaunch(SubStageType.reviewRetellParagraph, autoAdvance: true),
        ReviewLaunch.retellParagraph,
      );
      expect(
        planReviewLaunch(SubStageType.reviewRetellSummary, autoAdvance: true),
        ReviewLaunch.retellSummary,
      );
    });

    test('其余子步骤回到计划页，不自动弹简报', () {
      expect(
        planReviewLaunch(
          SubStageType.reviewDifficultPractice,
          autoAdvance: true,
        ),
        ReviewLaunch.none,
      );
      expect(
        planReviewLaunch(SubStageType.intensiveListen, autoAdvance: true),
        ReviewLaunch.none,
      );
    });

    test('两个入口对同一子步骤的差异只来自 autoAdvance', () {
      for (final subStage in SubStageType.values) {
        final manual = planReviewLaunch(subStage, autoAdvance: false);
        final auto = planReviewLaunch(subStage, autoAdvance: true);
        expect(
          manual,
          isNot(ReviewLaunch.none),
          reason: '用户主动点击 $subStage 不应无反应',
        );
        if (manual == ReviewLaunch.blindListen ||
            manual == ReviewLaunch.retellParagraph) {
          expect(auto, manual, reason: '自带弹窗的 $subStage 自动推进可直接进入');
        } else {
          expect(
            auto,
            isNot(ReviewLaunch.briefing),
            reason: '自动推进 $subStage 不应弹简报',
          );
        }
      }
    });
  });
}
