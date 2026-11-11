import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/sentence.dart';
import 'package:loop_back/services/silence_skip_detector.dart';

/// 构造测试字幕（毫秒粒度）
Sentence _s(int idx, int startMs, int endMs) => Sentence(
  index: idx,
  text: 's$idx',
  startTime: Duration(milliseconds: startMs),
  endTime: Duration(milliseconds: endMs),
);

void main() {
  group('SilenceSkipDetector - 中间 gap', () {
    // 句 0: 0..2s, 句 1: 12s..14s（gap = 10s）, 句 2: 14.5s..16s（gap = 0.5s）
    final sentences = [
      _s(0, 0, 2000),
      _s(1, 12000, 14000),
      _s(2, 14500, 16000),
    ];
    const playbackEnd = Duration(milliseconds: 16000);

    test('gap < threshold 不跳过', () {
      final r = SilenceSkipDetector.detect(
        position: const Duration(milliseconds: 14200),
        sentences: sentences,
        currentIdx: 2,
        thresholdSeconds: 2,
        playbackEnd: playbackEnd,
      );
      expect(r, isNull); // gap = 0.5s < 2
    });

    test('在 prevEnd+1s 缓冲内不跳过', () {
      final r = SilenceSkipDetector.detect(
        position: const Duration(milliseconds: 2500),
        sentences: sentences,
        currentIdx: 1,
        thresholdSeconds: 2,
        playbackEnd: playbackEnd,
      );
      expect(r, isNull);
    });

    test('距 nextStart ≤ 1s 不跳过', () {
      final r = SilenceSkipDetector.detect(
        position: const Duration(milliseconds: 11500),
        sentences: sentences,
        currentIdx: 1,
        thresholdSeconds: 2,
        playbackEnd: playbackEnd,
      );
      expect(r, isNull);
    });

    test('刚过 prevEnd+1s → 跳到 next-1s', () {
      final r = SilenceSkipDetector.detect(
        position: const Duration(milliseconds: 3000), // prevEnd=2s + 1s
        sentences: sentences,
        currentIdx: 1,
        thresholdSeconds: 2,
        playbackEnd: playbackEnd,
      );
      expect(r, isNotNull);
      expect(r!.skipTo, const Duration(milliseconds: 11000));
      expect(r.gapDuration, const Duration(milliseconds: 10000));
      expect(r.dedupKey, 1);
    });

    test('阈值 == gap 时窗口重合为空 → 不跳过', () {
      // gap == threshold 时 pastBuffer 与 stillRoom 窗口不重叠，无可跳过的位置。
      final s2 = [_s(0, 0, 1000), _s(1, 3000, 4000)]; // gap = 2s
      final r = SilenceSkipDetector.detect(
        position: const Duration(milliseconds: 2000),
        sentences: s2,
        currentIdx: 1,
        thresholdSeconds: 2,
        playbackEnd: const Duration(milliseconds: 4000),
      );
      expect(r, isNull);
    });

    test('gap 略大于 threshold → 跳过', () {
      // gap = 2.5s, threshold = 2s → 跳过窗口存在
      final s2 = [_s(0, 0, 1000), _s(1, 3500, 4500)];
      final r = SilenceSkipDetector.detect(
        position: const Duration(milliseconds: 2100),
        sentences: s2,
        currentIdx: 1,
        thresholdSeconds: 2,
        playbackEnd: const Duration(milliseconds: 4500),
      );
      expect(r, isNotNull);
      expect(r!.skipTo, const Duration(milliseconds: 2500));
    });
  });

  group('SilenceSkipDetector - 开头', () {
    test('first.start < threshold/2 不跳过', () {
      final s = [
        _s(0, 800, 2000),
      ]; // first=0.8s, threshold=2 → boundary=1, 0<1 不触发
      final r = SilenceSkipDetector.detect(
        position: Duration.zero,
        sentences: s,
        currentIdx: 0,
        thresholdSeconds: 2,
        playbackEnd: const Duration(milliseconds: 2000),
      );
      expect(r, isNull);
    });

    test('first.start ≥ boundary 且 position 距 first 充足 → 跳到 first-1s', () {
      final s = [_s(0, 5000, 7000)];
      final r = SilenceSkipDetector.detect(
        position: const Duration(milliseconds: 200),
        sentences: s,
        currentIdx: 0,
        thresholdSeconds: 2,
        playbackEnd: const Duration(milliseconds: 7000),
      );
      expect(r, isNotNull);
      expect(r!.skipTo, const Duration(milliseconds: 4000));
      expect(r.dedupKey, 0);
    });

    test('position 距 first ≤ 1s 不跳过', () {
      final s = [_s(0, 5000, 7000)];
      final r = SilenceSkipDetector.detect(
        position: const Duration(milliseconds: 4500),
        sentences: s,
        currentIdx: 0,
        thresholdSeconds: 2,
        playbackEnd: const Duration(milliseconds: 7000),
      );
      expect(r, isNull);
    });

    test('阈值砍半向上取整：threshold=3 → boundary=2', () {
      final s = [
        _s(0, 1500, 3000),
      ]; // first=1.5s, threshold=3 → boundary=2, 1.5<2 不触发
      final r = SilenceSkipDetector.detect(
        position: Duration.zero,
        sentences: s,
        currentIdx: 0,
        thresholdSeconds: 3,
        playbackEnd: const Duration(milliseconds: 3000),
      );
      expect(r, isNull);
    });
  });

  group('SilenceSkipDetector - 末尾', () {
    test('playbackEnd == last.end（blind/retell 实际场景）→ 永远 null', () {
      final s = [_s(0, 0, 2000), _s(1, 3000, 5000)];
      final r = SilenceSkipDetector.detect(
        position: const Duration(milliseconds: 5500),
        sentences: s,
        currentIdx: 1,
        thresholdSeconds: 2,
        playbackEnd: const Duration(milliseconds: 5000),
      );
      expect(r, isNull);
    });

    test('tailGap < boundary 不跳过', () {
      final s = [_s(0, 0, 5000)];
      final r = SilenceSkipDetector.detect(
        position: const Duration(milliseconds: 6500),
        sentences: s,
        currentIdx: 0,
        thresholdSeconds: 2,
        playbackEnd: const Duration(milliseconds: 5500), // tail=0.5s
      );
      expect(r, isNull);
    });

    test('在 last.end+1s 缓冲内不跳过', () {
      final s = [_s(0, 0, 5000)];
      final r = SilenceSkipDetector.detect(
        position: const Duration(milliseconds: 5500),
        sentences: s,
        currentIdx: 0,
        thresholdSeconds: 2,
        playbackEnd: const Duration(milliseconds: 30000),
      );
      expect(r, isNull);
    });

    test('过缓冲 + 充足 tailGap → 跳到 playbackEnd', () {
      final s = [_s(0, 0, 5000)];
      final r = SilenceSkipDetector.detect(
        position: const Duration(milliseconds: 6500),
        sentences: s,
        currentIdx: 0,
        thresholdSeconds: 2,
        playbackEnd: const Duration(milliseconds: 30000),
      );
      expect(r, isNotNull);
      expect(r!.skipTo, const Duration(milliseconds: 30000));
      expect(r.gapDuration, const Duration(milliseconds: 25000));
      expect(r.dedupKey, 1); // sentences.length
    });
  });

  group('SilenceSkipDetector - 防御', () {
    test('空字幕 → null', () {
      final r = SilenceSkipDetector.detect(
        position: Duration.zero,
        sentences: const [],
        currentIdx: 0,
        thresholdSeconds: 2,
        playbackEnd: Duration.zero,
      );
      expect(r, isNull);
    });

    test('在某句区间内 → null（不在 gap 中）', () {
      final s = [_s(0, 0, 2000), _s(1, 5000, 7000)];
      final r = SilenceSkipDetector.detect(
        position: const Duration(milliseconds: 1000),
        sentences: s,
        currentIdx: 0,
        thresholdSeconds: 2,
        playbackEnd: const Duration(milliseconds: 7000),
      );
      expect(r, isNull);
    });
  });
}
