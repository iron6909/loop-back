import 'package:loop_back/features/memory_scheduler/domain/memory_rating.dart';
import 'package:loop_back/features/memory_scheduler/domain/review_retention.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('deduplicates items and preserves the first Again result', () {
    final result = ReviewRetentionCalculator.calculate([
      const ReviewRetentionEvent(subjectId: 'a', rating: MemoryRating.again),
      const ReviewRetentionEvent(subjectId: 'a', rating: MemoryRating.good),
      const ReviewRetentionEvent(subjectId: 'b', rating: MemoryRating.good),
      const ReviewRetentionEvent(subjectId: 'c', rating: MemoryRating.easy),
    ]);

    expect(result.totalUniqueItems, 3);
    expect(result.retainedUniqueItems, 2);
    expect(result.retentionRate, closeTo(2 / 3, 0.0001));
    expect(result.againUniqueItems, 1);
    expect(result.goodUniqueItems, 1);
    expect(result.easyUniqueItems, 1);
  });

  test('empty events produce zero retention', () {
    final result = ReviewRetentionCalculator.calculate(const []);

    expect(result.totalUniqueItems, 0);
    expect(result.retentionRate, 0);
  });
}
