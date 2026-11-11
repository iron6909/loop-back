import 'package:loop_back/features/scheduled_flashcard/domain/review_session_summary.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_rating.dart';
import 'package:loop_back/features/memory_scheduler/domain/review_retention.dart';
import 'package:loop_back/theme/app_theme.dart';
import 'package:loop_back/widgets/review/review_completion_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';

void main() {
  testWidgets('shows a done button and invokes the exit callback', (
    tester,
  ) async {
    var exitCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ReviewCompletionSummary(
            title: '收藏句复习已完成',
            summary: const ReviewSessionSummary(
              elapsed: Duration.zero,
              reviewedCount: 1,
              againCount: 0,
              goodCount: 1,
              easyCount: 0,
              retentionEvents: [
                ReviewRetentionEvent(subjectId: 'a', rating: MemoryRating.good),
              ],
            ),
            onExit: () => exitCount += 1,
            doneLabel: '完成',
            durationLabel: '复习时长',
            reviewedLabel: '复习条数',
            retentionLabel: '保持率',
            ratingsLabel: '评分分布',
            againLabel: '听不懂',
            goodLabel: '听懂了',
            easyLabel: '轻松听懂',
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('review-completion-done')), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    await tester.tap(find.byKey(const Key('review-completion-done')));
    expect(exitCount, 1);
  });

  testWidgets(
    'shows one-shot confetti animation, summary metrics, and rating proportions',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ReviewCompletionSummary(
              title: '收藏句复习已完成',
              summary: ReviewSessionSummary(
                elapsed: Duration(minutes: 2, seconds: 8),
                reviewedCount: 2,
                againCount: 1,
                goodCount: 1,
                easyCount: 1,
                retentionEvents: [
                  ReviewRetentionEvent(
                    subjectId: 'a',
                    rating: MemoryRating.again,
                  ),
                  ReviewRetentionEvent(
                    subjectId: 'b',
                    rating: MemoryRating.good,
                  ),
                  ReviewRetentionEvent(
                    subjectId: 'c',
                    rating: MemoryRating.easy,
                  ),
                ],
              ),
              onExit: () {},
              doneLabel: '完成',
              durationLabel: '复习时长',
              reviewedLabel: '复习条数',
              retentionLabel: '保持率',
              ratingsLabel: '评分分布',
              againLabel: '听不懂',
              goodLabel: '听懂了',
              easyLabel: '轻松听懂',
            ),
          ),
        ),
      );

      final confetti = find.byKey(const Key('review-completion-confetti'));
      expect(confetti, findsOneWidget);
      expect(find.byType(LottieBuilder), findsOneWidget);
      final animation = tester.widget<LottieBuilder>(confetti);
      expect(animation.repeat, isTrue);
      expect(animation.animate, isFalse);
      expect(tester.getSize(confetti), const Size(160, 160));
      await tester.pump(const Duration(milliseconds: 499));
      expect(tester.widget<LottieBuilder>(confetti).animate, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(tester.widget<LottieBuilder>(confetti).animate, isTrue);
      expect(find.text('🎉'), findsNothing);
      expect(find.byKey(const Key('review-completion-title')), findsOneWidget);
      expect(find.text('收藏句复习已完成'), findsOneWidget);
      expect(find.text('2m 8s'), findsOneWidget);
      expect(find.text('66.7%'), findsOneWidget);
      expect(find.text('🧠'), findsOneWidget);
      expect(find.byKey(const Key('review-completion-again')), findsOneWidget);
      expect(find.byKey(const Key('review-completion-good')), findsOneWidget);
      expect(find.byKey(const Key('review-completion-easy')), findsOneWidget);
      expect(find.text('听不懂'), findsOneWidget);
      expect(find.text('1'), findsNWidgets(3));
      expect(find.text('33.3%'), findsNWidgets(3));
    },
  );
}
