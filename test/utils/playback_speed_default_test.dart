import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/database/enums.dart';
import 'package:loop_back/utils/playback_speed_default.dart';

void main() {
  group('defaultPlaybackSpeedFor', () {
    test('中等及以下难度任何轮次都保持 1.0x', () {
      for (final difficulty in [
        DifficultyLevel.veryEasy,
        DifficultyLevel.easy,
        DifficultyLevel.medium,
      ]) {
        for (final stage in LearningStage.values) {
          expect(
            defaultPlaybackSpeedFor(difficulty, stage),
            1.0,
            reason: '$difficulty @ $stage 应为 1.0x',
          );
        }
      }
    });

    test('困难难度按轮次回升：0.90 → 1.0', () {
      const d = DifficultyLevel.hard;
      expect(defaultPlaybackSpeedFor(d, LearningStage.firstLearn), 0.9);
      expect(defaultPlaybackSpeedFor(d, LearningStage.review0), 0.9);
      expect(defaultPlaybackSpeedFor(d, LearningStage.review1), 0.9);
      expect(defaultPlaybackSpeedFor(d, LearningStage.review2), 0.90);
      expect(defaultPlaybackSpeedFor(d, LearningStage.review4), 0.90);
      expect(defaultPlaybackSpeedFor(d, LearningStage.review7), 1.0);
      expect(defaultPlaybackSpeedFor(d, LearningStage.review14), 1.0);
      expect(defaultPlaybackSpeedFor(d, LearningStage.review28), 1.0);
      expect(defaultPlaybackSpeedFor(d, LearningStage.completed), 1.0);
    });

    test('很困难难度按轮次回升：0.80 → 0.90 → 1.0', () {
      const d = DifficultyLevel.veryHard;
      expect(defaultPlaybackSpeedFor(d, LearningStage.firstLearn), 0.8);
      expect(defaultPlaybackSpeedFor(d, LearningStage.review0), 0.80);
      expect(defaultPlaybackSpeedFor(d, LearningStage.review1), 0.80);
      expect(defaultPlaybackSpeedFor(d, LearningStage.review2), 0.9);
      expect(defaultPlaybackSpeedFor(d, LearningStage.review4), 0.9);
      expect(defaultPlaybackSpeedFor(d, LearningStage.review7), 0.90);
      expect(defaultPlaybackSpeedFor(d, LearningStage.review14), 1.0);
      expect(defaultPlaybackSpeedFor(d, LearningStage.review28), 1.0);
      expect(defaultPlaybackSpeedFor(d, LearningStage.completed), 1.0);
    });
  });
}
