/// playback_reducer 纯函数单元测试
///
/// 覆盖 decideNext（越过当前句尾后该做什么）在「整篇循环」「单句循环」两组独立开关的
/// 全部组合分支，以及 shouldLoopWhole（gapless 整段自然播完判定）。确保播放推进逻辑
/// 可独立验证，不依赖音频引擎。同时断言每个动作携带的 pauseBefore 间隔。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/providers/listening_practice/playback_reducer.dart';

void main() {
  const sInterval = Duration(seconds: 2);
  const wInterval = Duration(seconds: 5);

  /// 便捷构造：默认两个循环都关。
  NextAction next({
    bool loopSentence = false,
    int sentenceLoopCount = 3,
    bool loopWhole = false,
    int wholeLoopCount = 3,
    int sentenceRepeatsDone = 1,
    int wholeLoopsDone = 0,
    int currentPos = 0,
    int playableCount = 5,
  }) {
    return decideNext(
      loopSentence: loopSentence,
      sentenceLoopCount: sentenceLoopCount,
      sentenceInterval: sInterval,
      loopWhole: loopWhole,
      wholeLoopCount: wholeLoopCount,
      wholeInterval: wInterval,
      sentenceRepeatsDone: sentenceRepeatsDone,
      wholeLoopsDone: wholeLoopsDone,
      currentPos: currentPos,
      playableCount: playableCount,
    );
  }

  group('decideNext - 单句循环', () {
    test('∞：永远重播当前句，间隔为单句间隔', () {
      for (final r in [1, 5, 100]) {
        final a = next(
          loopSentence: true,
          sentenceLoopCount: 0,
          sentenceRepeatsDone: r,
          currentPos: 2,
        );
        expect(a, isA<ReplayCurrent>());
        expect((a as ReplayCurrent).pauseBefore, sInterval);
      }
    });

    test('有限：未到次数重播当前句', () {
      final a = next(
        loopSentence: true,
        sentenceLoopCount: 3,
        sentenceRepeatsDone: 2,
        currentPos: 1,
      );
      expect(a, isA<ReplayCurrent>());
      expect((a as ReplayCurrent).pauseBefore, sInterval);
    });

    test('有限：到次数后进下一句，间隔为单句间隔', () {
      final a = next(
        loopSentence: true,
        sentenceLoopCount: 3,
        sentenceRepeatsDone: 3,
        currentPos: 1,
      );
      expect((a as GoToPosition).position, 2);
      expect(a.pauseBefore, sInterval);
    });

    test('有限：到次数且在末尾、整篇循环关→停止', () {
      final a = next(
        loopSentence: true,
        sentenceLoopCount: 3,
        sentenceRepeatsDone: 3,
        currentPos: 4,
      );
      expect(a, isA<StopPlayback>());
    });
  });

  group('decideNext - 单句循环关、逐句推进（如收藏跳播）', () {
    test('句间推进无停顿（Duration.zero）', () {
      final a = next(currentPos: 1);
      expect((a as GoToPosition).position, 2);
      expect(a.pauseBefore, Duration.zero);
    });

    test('末尾、仅整篇循环开：按整篇间隔回卷', () {
      final a = next(
        loopWhole: true,
        wholeLoopCount: 2,
        wholeLoopsDone: 1,
        currentPos: 4,
      );
      expect((a as GoToPosition).position, 0);
      expect(a.pauseBefore, wInterval);
    });
  });

  group('decideNext - 单句+整篇两者同开（全程 trace）', () {
    // 3 句，单句循环 2 次，整篇循环 2 遍。
    test('当前句未重复够：重播', () {
      final a = next(
        loopSentence: true,
        sentenceLoopCount: 2,
        loopWhole: true,
        wholeLoopCount: 2,
        sentenceRepeatsDone: 1,
        currentPos: 0,
        playableCount: 3,
      );
      expect(a, isA<ReplayCurrent>());
      expect((a as ReplayCurrent).pauseBefore, sInterval);
    });

    test('当前句重复够、非末尾：进下一句（单句间隔）', () {
      final a = next(
        loopSentence: true,
        sentenceLoopCount: 2,
        loopWhole: true,
        wholeLoopCount: 2,
        sentenceRepeatsDone: 2,
        currentPos: 0,
        playableCount: 3,
      );
      expect((a as GoToPosition).position, 1);
      expect(a.pauseBefore, sInterval);
    });

    test('末尾句重复够、整篇未满：回卷（整篇间隔）', () {
      final a = next(
        loopSentence: true,
        sentenceLoopCount: 2,
        loopWhole: true,
        wholeLoopCount: 2,
        sentenceRepeatsDone: 2,
        wholeLoopsDone: 1,
        currentPos: 2,
        playableCount: 3,
      );
      expect((a as GoToPosition).position, 0);
      expect(a.pauseBefore, wInterval);
    });

    test('末尾句重复够、整篇已满：停止', () {
      final a = next(
        loopSentence: true,
        sentenceLoopCount: 2,
        loopWhole: true,
        wholeLoopCount: 2,
        sentenceRepeatsDone: 2,
        wholeLoopsDone: 2,
        currentPos: 2,
        playableCount: 3,
      );
      expect(a, isA<StopPlayback>());
    });
  });

  group('decideNext - 边界', () {
    test('播放列表为空时停止', () {
      final a = next(loopWhole: true, playableCount: 0);
      expect(a, isA<StopPlayback>());
    });

    test('两者全关、非末尾：顺次推进（无停顿）', () {
      final a = next(currentPos: 1);
      expect((a as GoToPosition).position, 2);
      expect(a.pauseBefore, Duration.zero);
    });

    test('两者全关、末尾：停止', () {
      final a = next(currentPos: 4);
      expect(a, isA<StopPlayback>());
    });
  });

  group('shouldLoopWhole - gapless 整段自然播完判定', () {
    test('整篇循环关闭：不回卷', () {
      expect(shouldLoopWhole(false, 3, 0), isFalse);
    });

    test('整篇循环 ∞：永远回卷', () {
      for (final done in [0, 1, 100]) {
        expect(shouldLoopWhole(true, 0, done), isTrue);
      }
    });

    test('整篇循环有限：未达遍数回卷，达到则停止', () {
      expect(shouldLoopWhole(true, 3, 2), isTrue);
      expect(shouldLoopWhole(true, 3, 3), isFalse);
    });
  });
}
