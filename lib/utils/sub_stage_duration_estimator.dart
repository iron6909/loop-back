/// 学习计划各子步骤的时长估算。
///
/// 计划页与复习简报共用同一套口径；估算只依赖传入的数据、不读 provider，因此
/// 两个入口不会算出不同的数字，也能脱离 widget 直接测试。
library;

import '../database/enums.dart';
import '../models/sentence.dart';
import 'blind_listen_duration_estimator.dart';
import 'learning_duration_estimator.dart';
import 'retell_duration_estimator.dart';

/// 估算某个子步骤的时长；不支持预估的子步骤返回 null。
///
/// - [SubStageType.blindListen]：盲听按字幕有效时长（跳过静音）或音频总时长。
/// - [SubStageType.reviewDifficultPractice]：难句时长 ×（盲听遍数 + 跟读遍数）。
/// - [SubStageType.reviewRetellSummary]：全文复述按真实播放 + smart 停顿。
Duration? estimateSubStageDuration({
  required SubStageType subStage,
  required List<Sentence> sentences,
  required Duration? fullAudioDuration,
  required bool skipSilenceEnabled,
  int difficultBlindListenRepeatCount = 1,
  int difficultShadowReadingRepeatCount = 3,
  int retellRepeatCount = 1,
}) {
  switch (subStage) {
    case SubStageType.blindListen:
      return estimateBlindListenSessionDuration(
        sentences: sentences,
        fullAudioDuration: fullAudioDuration,
        skipSilenceEnabled: skipSilenceEnabled,
      );
    case SubStageType.reviewDifficultPractice:
      final difficultDuration = sentences
          .where((sentence) => sentence.isBookmarked)
          .fold<Duration>(
            Duration.zero,
            (sum, sentence) => sum + sentence.duration,
          );
      return estimateDifficultPracticeDuration(
        difficultSentenceDuration: difficultDuration,
        blindListenRepeatCount: difficultBlindListenRepeatCount,
        shadowReadingRepeatCount: difficultShadowReadingRepeatCount,
      );
    case SubStageType.reviewRetellSummary:
      // 全文作为单段复述，pauseMultiplier=-1 走 smart 停顿。
      if (retellRepeatCount == 0 || sentences.isEmpty) return null;
      return estimateRetellSessionDuration(
        sentences: sentences,
        targetSeconds: -1,
        pauseMultiplier: -1,
        repeatCount: retellRepeatCount,
      );
    default:
      return null;
  }
}
