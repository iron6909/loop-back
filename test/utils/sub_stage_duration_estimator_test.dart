import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/database/enums.dart';
import 'package:loop_back/models/sentence.dart';
import 'package:loop_back/utils/retell_duration_estimator.dart';
import 'package:loop_back/utils/sub_stage_duration_estimator.dart';

/// 造一句带时间区间的字幕。
Sentence _sentence(
  int index, {
  required int startMs,
  required int endMs,
  bool bookmarked = false,
}) => Sentence(
  index: index,
  text: 'sentence $index',
  startTime: Duration(milliseconds: startMs),
  endTime: Duration(milliseconds: endMs),
  isBookmarked: bookmarked,
);

void main() {
  final sentences = [
    _sentence(0, startMs: 0, endMs: 3000),
    _sentence(1, startMs: 5000, endMs: 8000, bookmarked: true),
    _sentence(2, startMs: 10000, endMs: 12000),
  ];

  group('estimateSubStageDuration', () {
    test('盲听：跳静音开启时按字幕有效时长', () {
      expect(
        estimateSubStageDuration(
          subStage: SubStageType.blindListen,
          sentences: sentences,
          fullAudioDuration: const Duration(minutes: 10),
          skipSilenceEnabled: true,
        ),
        const Duration(milliseconds: 8000),
      );
    });

    test('盲听：跳静音关闭时按音频总时长', () {
      expect(
        estimateSubStageDuration(
          subStage: SubStageType.blindListen,
          sentences: sentences,
          fullAudioDuration: const Duration(minutes: 10),
          skipSilenceEnabled: false,
        ),
        const Duration(minutes: 10),
      );
    });

    test('难句补练：只累计被收藏的句子并按遍数相乘', () {
      expect(
        estimateSubStageDuration(
          subStage: SubStageType.reviewDifficultPractice,
          sentences: sentences,
          fullAudioDuration: const Duration(minutes: 10),
          skipSilenceEnabled: false,
          difficultBlindListenRepeatCount: 2,
          difficultShadowReadingRepeatCount: 3,
        ),
        const Duration(seconds: 15),
      );
    });

    test('难句补练：无限循环时不返回有限时长', () {
      expect(
        estimateSubStageDuration(
          subStage: SubStageType.reviewDifficultPractice,
          sentences: sentences,
          fullAudioDuration: null,
          skipSilenceEnabled: false,
          difficultBlindListenRepeatCount: 0,
        ),
        isNull,
      );
    });

    test('全文复述：与复述估算器同一口径', () {
      final expected = estimateRetellSessionDuration(
        sentences: sentences,
        targetSeconds: -1,
        pauseMultiplier: -1,
        repeatCount: 1,
      );
      expect(
        estimateSubStageDuration(
          subStage: SubStageType.reviewRetellSummary,
          sentences: sentences,
          fullAudioDuration: const Duration(minutes: 10),
          skipSilenceEnabled: false,
        ),
        expected,
      );
    });

    test('全文复述：没有字幕或无限循环时返回 null', () {
      expect(
        estimateSubStageDuration(
          subStage: SubStageType.reviewRetellSummary,
          sentences: const [],
          fullAudioDuration: const Duration(minutes: 10),
          skipSilenceEnabled: false,
        ),
        isNull,
      );
      expect(
        estimateSubStageDuration(
          subStage: SubStageType.reviewRetellSummary,
          sentences: sentences,
          fullAudioDuration: null,
          skipSilenceEnabled: false,
          retellRepeatCount: 0,
        ),
        isNull,
      );
    });

    test('其他子步骤不展示预估时长', () {
      expect(
        estimateSubStageDuration(
          subStage: SubStageType.intensiveListen,
          sentences: sentences,
          fullAudioDuration: const Duration(minutes: 10),
          skipSilenceEnabled: false,
        ),
        isNull,
      );
    });
  });
}
