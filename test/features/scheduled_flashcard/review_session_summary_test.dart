import 'package:loop_back/features/memory_scheduler/domain/memory_rating.dart';
import 'package:loop_back/features/scheduled_flashcard/domain/review_session_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses each item first rating for retention and distribution', () {
    final summary = const ReviewSessionSummary()
        .recordRating(subjectId: 'a', rating: MemoryRating.again)
        .recordRating(subjectId: 'a', rating: MemoryRating.good)
        .recordRating(subjectId: 'b', rating: MemoryRating.good)
        .recordRating(subjectId: 'c', rating: MemoryRating.easy)
        .complete(
          elapsed: const Duration(minutes: 2, seconds: 8),
          reviewedCount: 2,
        );

    expect(summary.againCount, 1);
    expect(summary.goodCount, 1);
    expect(summary.easyCount, 1);
    expect(summary.ratingCount, 3);
    expect(summary.reviewedCount, 2);
    expect(summary.elapsed, const Duration(minutes: 2, seconds: 8));
    expect(summary.retentionRate, closeTo(2 / 3, 0.0001));
  });
}
