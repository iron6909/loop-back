import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/database/enums.dart';
import 'package:loop_back/models/learning_progress.dart';
import 'package:loop_back/utils/learning_start_planner.dart';

LearningProgress _progress({
  LearningStage stage = LearningStage.firstLearn,
  SubStageType subStage = SubStageType.blindListen,
  DateTime? lastStageCompletedAt,
  required DateTime now,
}) => LearningProgress(
  audioItemId: 'audio-1',
  currentStage: stage,
  currentSubStage: subStage,
  lastStageCompletedAt: lastStageCompletedAt,
  updatedAt: now,
);

void main() {
  final now = DateTime(2026, 11, 14, 12);

  group('planLearningStart', () {
    test('复习未到时间时什么都不启动', () {
      expect(
        planLearningStart(
          progress: _progress(
            stage: LearningStage.review0,
            lastStageCompletedAt: now,
            now: now,
          ),
          now: now,
        ),
        LearningStartAction.blocked,
      );
    });

    test('复习已到时间时进入复习子步骤分发', () {
      expect(
        planLearningStart(
          progress: _progress(
            stage: LearningStage.review1,
            lastStageCompletedAt: now.subtract(const Duration(days: 30)),
            now: now,
          ),
          now: now,
        ),
        LearningStartAction.reviewSubStage,
      );
    });

    test('首次学习按子步骤分派到对应流程', () {
      expect(
        planLearningStart(
          progress: _progress(subStage: SubStageType.blindListen, now: now),
          now: now,
        ),
        LearningStartAction.blindListen,
      );
      expect(
        planLearningStart(
          progress: _progress(subStage: SubStageType.intensiveListen, now: now),
          now: now,
        ),
        LearningStartAction.intensiveListen,
      );
      expect(
        planLearningStart(
          progress: _progress(subStage: SubStageType.listenAndRepeat, now: now),
          now: now,
        ),
        LearningStartAction.listenAndRepeat,
      );
      expect(
        planLearningStart(
          progress: _progress(subStage: SubStageType.retell, now: now),
          now: now,
        ),
        LearningStartAction.retell,
      );
    });

    test('未识别的子步骤兜底到随心听，不会卡住入口', () {
      expect(
        planLearningStart(
          progress: _progress(
            subStage: SubStageType.reviewDifficultPractice,
            now: now,
          ),
          now: now,
        ),
        LearningStartAction.freePlay,
      );
    });
  });
}
