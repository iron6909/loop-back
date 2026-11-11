import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/database/enums.dart';
import 'package:loop_back/utils/difficulty_from_ratio.dart';

void main() {
  group('difficultyFromDifficultRatio', () {
    test('total<=0 → veryEasy', () {
      expect(difficultyFromDifficultRatio(0, 0), DifficultyLevel.veryEasy);
      expect(difficultyFromDifficultRatio(-1, 3), DifficultyLevel.veryEasy);
    });

    test('ratio==0 → veryEasy', () {
      expect(difficultyFromDifficultRatio(20, 0), DifficultyLevel.veryEasy);
    });

    test('ratio<=5% → easy（边界 5%）', () {
      expect(difficultyFromDifficultRatio(100, 1), DifficultyLevel.easy);
      expect(difficultyFromDifficultRatio(100, 5), DifficultyLevel.easy);
    });

    test('5%<ratio<=15% → medium（边界 15%）', () {
      expect(difficultyFromDifficultRatio(100, 6), DifficultyLevel.medium);
      expect(
        difficultyFromDifficultRatio(10, 1),
        DifficultyLevel.medium,
      ); // 10%
      expect(difficultyFromDifficultRatio(100, 15), DifficultyLevel.medium);
    });

    test('15%<ratio<=30% → hard（边界 30%）', () {
      expect(difficultyFromDifficultRatio(100, 16), DifficultyLevel.hard);
      expect(difficultyFromDifficultRatio(100, 30), DifficultyLevel.hard);
    });

    test('ratio>30% → veryHard', () {
      expect(difficultyFromDifficultRatio(100, 31), DifficultyLevel.veryHard);
      expect(
        difficultyFromDifficultRatio(10, 4),
        DifficultyLevel.veryHard,
      ); // 40%
    });
  });
}
