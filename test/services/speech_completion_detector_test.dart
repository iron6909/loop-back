import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/services/speech_completion_detector.dart';

/// 快速构建 SpeechMatchContext
SpeechMatchContext buildCtx(String reference, String transcript) {
  return buildMatchContext(
    referenceText: reference,
    partialTranscript: transcript,
  );
}

void main() {
  // 10 个不重复的单词，用于需要精确定位的测试
  // "alpha bravo charlie delta echo foxtrot golf hotel india juliet"
  const tenWords =
      'alpha bravo charlie delta echo foxtrot golf hotel india juliet';

  // ================================================================
  // 检测 D：剩余词数估算阈值
  // ================================================================
  group('detectRemainingByPosition (规则 D)', () {
    // ── 基本触发 ──

    test('末尾 1 词在 reference 中唯一，有剩余词 → 触发', () {
      // transcript: "alpha bravo charlie" → 末尾 "charlie" 在 reference index 2 唯一
      // remaining = 10 - 3 = 7
      final ctx = buildCtx(tenWords, 'alpha bravo charlie');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isTrue);
      // base=1 + 7*1 = 8s
      expect(result.threshold, const Duration(seconds: 8));
    });

    test('末尾 3 词组成唯一子串 → 触发，用更可靠的长串定位', () {
      // reference: "she went to the big store on the corner"
      // transcript: "she went to the big store"
      // 末尾 5 词 "went to the big store" 唯一 → endIndex 5
      // remaining = 9 - 6 = 3
      final ctx = buildCtx(
        'she went to the big store on the corner',
        'she went to the big store',
      );
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isTrue);
      // base=1 + 3*1 = 4s
      expect(result.threshold, const Duration(seconds: 4));
    });

    test('末尾 5 词唯一子串 → 触发', () {
      // transcript: "alpha bravo charlie delta echo"
      // 末尾 5 词唯一 → endIndex 4, remaining = 10 - 5 = 5
      final ctx = buildCtx(tenWords, 'alpha bravo charlie delta echo');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isTrue);
      // base=1 + 5*1 = 6s
      expect(result.threshold, const Duration(seconds: 6));
    });

    // ── 优先长串 ──

    test('末尾 1 词和 3 词都唯一时 → 选最长（更可靠）', () {
      final ctx = buildCtx(tenWords, 'alpha bravo charlie');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isTrue);
      // 末尾 3 词 "alpha bravo charlie" 唯一 → 选 3 词
      expect(result.description, contains('3词'));
    });

    test('末尾 1 词唯一但 2 词不唯一 → 用 1 词', () {
      // reference: "go to go home now"
      // transcript: "go to go"
      // 末尾 1 词 "go" → 出现 3 次，非唯一
      // 末尾 2 词 "to go" → 出现 1 次 → 唯一
      // 末尾 3 词 "go to go" → 出现 1 次 → 唯一 → 最长优先
      final ctx = buildCtx('go to go home now', 'go to go');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isTrue);
      expect(result.description, contains('3词'));
    });

    // ── 不触发场景 ──

    test('transcript 为空 → 不触发', () {
      final ctx = buildCtx('hello world', '');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isFalse);
      expect(result.description, contains('transcript为空'));
    });

    test('reference 为空 → 不触发', () {
      final ctx = buildCtx('', 'hello');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isFalse);
      expect(result.description, contains('reference为空'));
    });

    test('末尾所有候选子串在 reference 中都非唯一 → 不触发', () {
      final ctx = buildCtx('the the the the the', 'the the');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isFalse);
      expect(result.description, contains('无唯一匹配'));
    });

    test('唯一匹配但 remaining == 0（已在末尾） → 不触发', () {
      final ctx = buildCtx('unique word', 'unique word');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isFalse);
      expect(result.description, contains('剩余0词'));
    });

    // ── 剩余词数计算 ──

    test('reference 10 词，匹配位置在第 3 词 → remaining = 7', () {
      // "charlie" 唯一, index 2, remaining = 10 - 3 = 7
      final ctx = buildCtx(tenWords, 'charlie');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 8)); // 1+7
    });

    test('reference 10 词，匹配位置在第 9 词（倒数第 2） → remaining = 1', () {
      // "india" 唯一, index 8, remaining = 10 - 9 = 1
      final ctx = buildCtx(tenWords, 'india');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 2)); // 1+1
    });

    test('reference 10 词，匹配位置在第 10 词（最后） → remaining = 0，不触发', () {
      // "juliet" 唯一, index 9, remaining = 0
      final ctx = buildCtx(tenWords, 'juliet');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isFalse);
    });

    // ── 参数差异 ──

    test('跟读默认参数（base=1, perWord=1）：remaining=5 → 6s', () {
      // "echo" 唯一, index 4, remaining = 10 - 5 = 5
      final ctx = buildCtx(tenWords, 'echo');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 6));
    });

    test('复述参数（base=2, perWord=3）：remaining=5 → 17s', () {
      final ctx = buildCtx(tenWords, 'echo');
      final result = detectRemainingByPosition(
        ctx,
        secondsPerWord: 3,
        baseSeconds: 2,
      );
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 17));
    });

    // ── 边界情况 ──

    test('transcript 只有 1 个词 → 只枚举长度 1 的子串', () {
      final ctx = buildCtx('hello world goodbye', 'world');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isTrue);
      // "world" 唯一, endIndex=1, remaining=1
      expect(result.threshold, const Duration(seconds: 2));
      expect(result.description, contains('1词'));
    });

    test('transcript 有 3 个词 → 枚举长度 1-3（不到 5）', () {
      final ctx = buildCtx(tenWords, 'alpha bravo charlie');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isTrue);
      // 末尾 3 词 "alpha bravo charlie" 唯一 → endIndex=2, remaining=7
      expect(result.threshold, const Duration(seconds: 8));
    });

    test('reference 中同一子串出现 2 次 → 非唯一，不触发', () {
      final ctx = buildCtx('go home go home', 'go home');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isFalse);
    });

    test('子串跨越 reference 中不同位置的相同词 → 正确判定唯一性', () {
      // reference: "big cat and small cat here"
      // "cat" 出现 2 次 → 非唯一
      // "small cat" 出现 1 次 (index 3-4) → 唯一! endIndex=4, remaining=1
      final ctx = buildCtx('big cat and small cat here', 'small cat');
      final result = detectRemainingByPosition(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 2)); // 1+1
    });
  });

  // ================================================================
  // 与其他规则的组合
  // ================================================================
  group('combineDetections 与规则 D 组合', () {
    test('D 触发但 A 给出更短阈值 → 取 A（最短）', () {
      // 完全匹配整句 → A 默认 1s（跟读行为），D 不触发（remaining=0）
      final ctx = buildCtx(tenWords, tenWords);
      final ruleD = detectRemainingByPosition(ctx);
      final ruleA = detectTailMatch(ctx);

      expect(ruleA.triggered, isTrue);
      expect(ruleA.threshold, const Duration(seconds: 1));
      expect(ruleD.triggered, isFalse);

      final combined = combineDetections(
        [ruleD, ruleA],
        ctx,
        fallback: const Duration(seconds: 5),
      );
      expect(combined.threshold, const Duration(seconds: 1));
    });

    test('D 触发且阈值最短 → 使用 D 的阈值', () {
      // transcript 说到 "india"(index 8), remaining=1 → D: 1+1=2s
      // C: 末尾 5 词命中 1 个 → 5s
      final ctx = buildCtx(tenWords, 'india');
      final ruleD = detectRemainingByPosition(ctx);
      final ruleC = detectTailHitCount(ctx);

      expect(ruleD.triggered, isTrue);
      expect(ruleD.threshold, const Duration(seconds: 2));
      expect(ruleC.triggered, isTrue);

      final combined = combineDetections(
        [ruleD, ruleC],
        ctx,
        fallback: const Duration(seconds: 5),
      );
      expect(combined.threshold, const Duration(seconds: 2));
    });
  });

  // ================================================================
  // 动态兜底：computeDynamicFallback
  // ================================================================
  group('computeDynamicFallback', () {
    // 基准：referenceDuration = 10s, speedFactor = 1.1 → adjustedDuration = 11s

    const ref10s = Duration(seconds: 10); // 原句 10s

    test('referenceDuration <= 0 → 返回 defaultFallback', () {
      expect(
        computeDynamicFallback(
          voicedDuration: const Duration(seconds: 15),
          referenceDuration: Duration.zero,
        ),
        const Duration(seconds: 5),
      );
    });

    test('matchRate < 0.8 → 返回 defaultFallback', () {
      expect(
        computeDynamicFallback(
          voicedDuration: const Duration(seconds: 15),
          referenceDuration: ref10s,
          matchRate: 0.5,
        ),
        const Duration(seconds: 5),
      );
    });

    test('matchRate = null（无转录）+ ratio >= 0.95 → 1s', () {
      // voiced = 10.5s, adjusted = 11s → ratio ≈ 0.955
      expect(
        computeDynamicFallback(
          voicedDuration: const Duration(milliseconds: 10500),
          referenceDuration: ref10s,
        ),
        const Duration(seconds: 1),
      );
    });

    test('matchRate = null + ratio >= 0.90 → 2s', () {
      // voiced = 9.9s, adjusted = 11s → ratio = 0.90
      expect(
        computeDynamicFallback(
          voicedDuration: const Duration(milliseconds: 9900),
          referenceDuration: ref10s,
        ),
        const Duration(seconds: 2),
      );
    });

    test('matchRate = null + ratio >= 0.85 → 3s', () {
      // voiced = 9.35s, adjusted = 11s → ratio = 0.85
      expect(
        computeDynamicFallback(
          voicedDuration: const Duration(milliseconds: 9350),
          referenceDuration: ref10s,
        ),
        const Duration(seconds: 3),
      );
    });

    test('matchRate = null + ratio >= 0.80 → 4s', () {
      // voiced = 8.8s, adjusted = 11s → ratio = 0.80
      expect(
        computeDynamicFallback(
          voicedDuration: const Duration(milliseconds: 8800),
          referenceDuration: ref10s,
        ),
        const Duration(seconds: 4),
      );
    });

    test('matchRate = null + ratio >= 0.75 → 5s', () {
      // voiced = 8.25s, adjusted = 11s → ratio = 0.75
      expect(
        computeDynamicFallback(
          voicedDuration: const Duration(milliseconds: 8250),
          referenceDuration: ref10s,
        ),
        const Duration(seconds: 5),
      );
    });

    test('matchRate = null + ratio < 0.75 → defaultFallback (5s)', () {
      // voiced = 8s, adjusted = 11s → ratio ≈ 0.727
      expect(
        computeDynamicFallback(
          voicedDuration: const Duration(seconds: 8),
          referenceDuration: ref10s,
        ),
        const Duration(seconds: 5),
      );
    });

    test('matchRate >= 0.8 时动态兜底生效', () {
      // voiced = 10.5s, adjusted = 11s → ratio ≈ 0.955, matchRate = 0.8 → 1s
      expect(
        computeDynamicFallback(
          voicedDuration: const Duration(milliseconds: 10500),
          referenceDuration: ref10s,
          matchRate: 0.8,
        ),
        const Duration(seconds: 1),
      );
    });

    test('matchRate = 0.79 时即使 ratio 很高也返回 defaultFallback', () {
      expect(
        computeDynamicFallback(
          voicedDuration: const Duration(seconds: 20),
          referenceDuration: ref10s,
          matchRate: 0.79,
        ),
        const Duration(seconds: 5),
      );
    });

    test('speedFactor 自定义', () {
      // ref = 10s, speedFactor = 1.0 → adjusted = 10s
      // voiced = 10s → ratio = 1.0 → 1s
      expect(
        computeDynamicFallback(
          voicedDuration: const Duration(seconds: 10),
          referenceDuration: ref10s,
          speedFactor: 1.0,
        ),
        const Duration(seconds: 1),
      );
    });
  });

  group('computeRetellDynamicFallback (收紧版 2026-05-18)', () {
    // 新规则：cap = clamp(refDur, 5s, 30s)，scale = capMs / 30000
    // 档位：≥0.95 → 6s×scale；≥0.90 → 12s×scale；≥0.85/0.80/0.75 → cap；<0.75 → cap
    // 下限 5s
    // ── ref=10s：cap=10s, scale=0.333, speedFactor=1.1, adjusted=11s ──

    const ref10s = Duration(seconds: 10);

    test('referenceDuration <= 0 → cap (clamp 到 5s)', () {
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(seconds: 15),
          referenceDuration: Duration.zero,
        ),
        const Duration(seconds: 5),
      );
    });

    test('matchRate < 0.8 → cap (10s)', () {
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(seconds: 15),
          referenceDuration: ref10s,
          matchRate: 0.5,
        ),
        const Duration(seconds: 10),
      );
    });

    test('ref=10s, ratio >= 0.95 → 5s (6×0.333=2s 被下限抬到 5s)', () {
      // voiced = 10.45s, adjusted = 11s → ratio = 0.95
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 10450),
          referenceDuration: ref10s,
        ),
        const Duration(seconds: 5),
      );
    });

    test('ref=10s, ratio >= 0.90 → 5s (12×0.333=4s 被下限抬到 5s)', () {
      // voiced = 9.9s, adjusted = 11s → ratio = 0.90
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 9900),
          referenceDuration: ref10s,
        ),
        const Duration(seconds: 5),
      );
    });

    test('ref=10s, ratio >= 0.85 → cap 10s', () {
      // voiced = 9.35s, adjusted = 11s → ratio = 0.85
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 9350),
          referenceDuration: ref10s,
        ),
        const Duration(seconds: 10),
      );
    });

    test('ref=10s, ratio >= 0.80 → cap 10s', () {
      // voiced = 8.8s, adjusted = 11s → ratio = 0.80
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 8800),
          referenceDuration: ref10s,
        ),
        const Duration(seconds: 10),
      );
    });

    test('ref=10s, ratio >= 0.75 → cap 10s', () {
      // voiced = 8.25s, adjusted = 11s → ratio = 0.75
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 8250),
          referenceDuration: ref10s,
        ),
        const Duration(seconds: 10),
      );
    });

    test('ref=10s, ratio < 0.75 → cap 10s', () {
      // voiced = 7s, adjusted = 11s → ratio ≈ 0.636
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(seconds: 7),
          referenceDuration: ref10s,
        ),
        const Duration(seconds: 10),
      );
    });

    test('matchRate >= 0.8 时动态兜底生效（仍受下限影响）', () {
      // voiced = 10.45s, adjusted = 11s → ratio = 0.95 → 2s → 下限 5s
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 10450),
          referenceDuration: ref10s,
          matchRate: 0.8,
        ),
        const Duration(seconds: 5),
      );
    });

    test('matchRate = 0.79 时即使 ratio 很高也返回 cap', () {
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(seconds: 20),
          referenceDuration: ref10s,
          matchRate: 0.79,
        ),
        const Duration(seconds: 10),
      );
    });

    // ── ref=20s：cap=20s, scale=0.667, speedFactor=1.2, adjusted=24s ──

    const ref20s = Duration(seconds: 20);

    test('ref=20s, ratio >= 0.95 → 5s (6×0.667=4s 被下限抬到 5s)', () {
      // voiced = 22.8s, adjusted = 24s → ratio = 0.95
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 22800),
          referenceDuration: ref20s,
        ),
        const Duration(seconds: 5),
      );
    });

    test('ref=20s, ratio >= 0.90 → 8s (12×0.667=8s)', () {
      // voiced = 21.6s, adjusted = 24s → ratio = 0.90
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 21600),
          referenceDuration: ref20s,
        ),
        const Duration(seconds: 8),
      );
    });

    test('ref=20s, ratio >= 0.80 → cap 20s', () {
      // voiced = 19.2s, adjusted = 24s → ratio = 0.80
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 19200),
          referenceDuration: ref20s,
        ),
        const Duration(seconds: 20),
      );
    });

    // ── ref=5s：cap=5s, scale=0.167, speedFactor=1.1, adjusted=5.5s ──

    const ref5s = Duration(seconds: 5);

    test('ref=5s, ratio >= 0.95 → 下限 5s', () {
      // 6000×0.167=1000ms → 下限 5000ms
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 5225),
          referenceDuration: ref5s,
        ),
        const Duration(seconds: 5),
      );
    });

    test('ref=5s, ratio >= 0.90 → 下限 5s', () {
      // 12000×0.167=2000ms → 下限 5000ms
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 4950),
          referenceDuration: ref5s,
        ),
        const Duration(seconds: 5),
      );
    });

    test('ref=5s, ratio < 0.75 → cap 5s', () {
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(seconds: 1),
          referenceDuration: ref5s,
        ),
        const Duration(seconds: 5),
      );
    });

    // ── ref=3s：cap=5s (clamp 抬到 5s), scale=0.167, speedFactor=1.0, adjusted=3s ──

    const ref3s = Duration(seconds: 3);

    test('ref=3s, ratio >= 0.95 → 下限 5s', () {
      // speedFactor=1.0, adjusted=3s, voiced=2.85s → ratio=0.95
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 2850),
          referenceDuration: ref3s,
        ),
        const Duration(seconds: 5),
      );
    });

    test('ref=3s, ratio < 0.75 → cap 5s', () {
      expect(
        computeRetellDynamicFallback(
          voicedDuration: Duration.zero,
          referenceDuration: ref3s,
        ),
        const Duration(seconds: 5),
      );
    });

    // ── ref=30s：cap=30s, scale=1.0, speedFactor=1.3, adjusted=39s ──

    const ref30s = Duration(seconds: 30);

    test('ref=30s, ratio >= 0.95 → 6s', () {
      // voiced = 37.05s, adjusted = 39s → ratio = 0.95
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 37050),
          referenceDuration: ref30s,
        ),
        const Duration(seconds: 6),
      );
    });

    test('ref=30s, ratio >= 0.90 → 12s', () {
      // voiced = 35.1s, adjusted = 39s → ratio = 0.90
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 35100),
          referenceDuration: ref30s,
        ),
        const Duration(seconds: 12),
      );
    });

    test('ref=30s, ratio < 0.75 → cap 30s (上限提到 30s)', () {
      expect(
        computeRetellDynamicFallback(
          voicedDuration: Duration.zero,
          referenceDuration: ref30s,
        ),
        const Duration(seconds: 30),
      );
    });

    // ── ref=60s：cap 仍为 30s（clamp 上限） ──

    test('ref=60s 时 cap 仍为 30s (clamp 上限)', () {
      expect(
        computeRetellDynamicFallback(
          voicedDuration: Duration.zero,
          referenceDuration: const Duration(seconds: 60),
        ),
        const Duration(seconds: 30),
      );
    });
  });

  // ================================================================
  // A 规则参数化验证（2026-05-18：复述场景收紧）
  // ================================================================
  group('detectTailMatch (默认 / 跟读模式)', () {
    test('尾部连续 1 词且唯一 → 触发 1s（默认）', () {
      final ctx = buildCtx(tenWords, 'juliet');
      final result = detectTailMatch(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 1));
    });

    test('原文末尾无匹配 → 不触发', () {
      final ctx = buildCtx(tenWords, 'alpha bravo charlie');
      final result = detectTailMatch(ctx);
      expect(result.triggered, isFalse);
      expect(result.description, contains('末尾未匹配'));
    });
  });

  group('detectTailMatch (复述收紧 minConsecutive=3, 1s)', () {
    DetectionResult retellA(SpeechMatchContext ctx) => detectTailMatch(
      ctx,
      minConsecutive: 3,
      triggerDuration: const Duration(seconds: 1),
    );

    test('尾部连续 1 词且唯一 → 不再触发（要求 ≥3）', () {
      final ctx = buildCtx(tenWords, 'juliet');
      final result = retellA(ctx);
      expect(result.triggered, isFalse);
      expect(result.description, contains('<3'));
    });

    test('尾部连续 2 词唯一 → 仍不触发', () {
      final ctx = buildCtx(tenWords, 'india juliet');
      final result = retellA(ctx);
      expect(result.triggered, isFalse);
    });

    test('尾部连续 3 词唯一 → 触发 1s', () {
      final ctx = buildCtx(tenWords, 'hotel india juliet');
      final result = retellA(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 1));
    });

    test('完整匹配整句 → 触发 1s', () {
      final ctx = buildCtx(tenWords, tenWords);
      final result = retellA(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 1));
    });

    test('尾部 3 词在原文中非唯一 → 不触发', () {
      // reference "a b c a b c"：末尾 a b c 出现 2 次
      final ctx = buildCtx('a b c a b c', 'a b c');
      final result = retellA(ctx);
      expect(result.triggered, isFalse);
      expect(result.description, contains('非唯一'));
    });

    test('原文末尾无匹配 → 不触发', () {
      final ctx = buildCtx(tenWords, 'alpha bravo charlie');
      final result = retellA(ctx);
      expect(result.triggered, isFalse);
    });

    test('reference 只有 3 词，全部匹配 → 触发 1s（边界）', () {
      final ctx = buildCtx('one two three', 'one two three');
      final result = retellA(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 1));
    });

    test('reference 只有 2 词，全部匹配 → 不触发（不足 3 词）', () {
      final ctx = buildCtx('hello world', 'hello world');
      final result = retellA(ctx);
      expect(result.triggered, isFalse);
    });
  });

  // ================================================================
  // B 规则参数化验证（2026-05-18：复述场景仅 100% 匹配）
  // ================================================================
  group('detectOverallMatchRate (默认 / 跟读模式)', () {
    test('100% 匹配 → 1s', () {
      final ctx = buildCtx(tenWords, tenWords);
      final result = detectOverallMatchRate(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 1));
    });

    test('95% 匹配 → 2s', () {
      const ref = 'a b c d e f g h i j k l m n o p q r s t';
      const transcript = 'a b c d e f g h i j k l m n o p q r s';
      final ctx = buildCtx(ref, transcript);
      final result = detectOverallMatchRate(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 2));
    });

    test('90% 匹配 → 3s', () {
      const ref = 'a b c d e f g h i j k l m n o p q r s t';
      const transcript = 'a b c d e f g h i j k l m n o p q r';
      final ctx = buildCtx(ref, transcript);
      final result = detectOverallMatchRate(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 3));
    });
  });

  group('detectOverallMatchRate (复述 strictPerfectOnly + 1s)', () {
    DetectionResult retellB(SpeechMatchContext ctx) => detectOverallMatchRate(
      ctx,
      strictPerfectOnly: true,
      perfectDuration: const Duration(seconds: 1),
    );

    test('100% 匹配 → 1s（高置信快速收尾）', () {
      final ctx = buildCtx(tenWords, tenWords);
      final result = retellB(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 1));
    });

    test('95% 匹配 → 不再触发', () {
      const ref = 'a b c d e f g h i j k l m n o p q r s t';
      const transcript = 'a b c d e f g h i j k l m n o p q r s';
      final ctx = buildCtx(ref, transcript);
      expect(ctx.matchRate, greaterThanOrEqualTo(0.95));
      final result = retellB(ctx);
      expect(result.triggered, isFalse);
      expect(result.description, contains('严格模式'));
    });

    test('90% 匹配 → 不再触发', () {
      const ref = 'a b c d e f g h i j k l m n o p q r s t';
      const transcript = 'a b c d e f g h i j k l m n o p q r';
      final ctx = buildCtx(ref, transcript);
      final result = retellB(ctx);
      expect(result.triggered, isFalse);
    });

    test('99% 匹配（仅差 1 词） → 不再触发', () {
      final refTokens = List.generate(100, (i) => 'w$i').join(' ');
      final transTokens = List.generate(99, (i) => 'w$i').join(' ');
      final ctx = buildCtx(refTokens, transTokens);
      expect(ctx.matchRate, closeTo(0.99, 0.001));
      final result = retellB(ctx);
      expect(result.triggered, isFalse);
    });

    test('无匹配（空 transcript） → 不触发', () {
      final ctx = buildCtx(tenWords, '');
      final result = retellB(ctx);
      expect(result.triggered, isFalse);
      expect(result.description, contains('无匹配'));
    });
  });

  // ================================================================
  // E 规则：近完成（matchRate ≥ 90% + 末尾命中 ≥4/5）
  // ================================================================
  group('detectNearCompletion (E 规则)', () {
    // 用 20 词原文，方便构造 95%、90% 等匹配率
    const twentyWords = 'a b c d e f g h i j k l m n o p q r s t';

    test('matchRate=100% + 末尾 5/5 → 触发 1s', () {
      final ctx = buildCtx(twentyWords, twentyWords);
      final result = detectNearCompletion(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 1));
    });

    test('matchRate=95% + 末尾 5/5 → 触发 1s', () {
      // 漏中段 1 词（"k"），末尾 5 词完整
      const transcript = 'a b c d e f g h i j l m n o p q r s t';
      final ctx = buildCtx(twentyWords, transcript);
      expect(ctx.matchRate, greaterThanOrEqualTo(0.95));
      final result = detectNearCompletion(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 1));
    });

    test('matchRate=90% + 末尾 4/5（漏末尾 1 词） → 触发 1s', () {
      // 漏 "s" 和 "k"：matchRate = 18/20 = 0.90
      // 末尾 5 词 (p q r s t) 命中 4 个（漏 s）
      const transcript = 'a b c d e f g h i j l m n o p q r t';
      final ctx = buildCtx(twentyWords, transcript);
      expect(ctx.matchRate, closeTo(0.90, 0.001));
      final result = detectNearCompletion(ctx);
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(seconds: 1));
    });

    test('matchRate=89% < 90% → 不触发（即使末尾 5/5）', () {
      // 漏中段 3 词 (j k l)：17/20 = 0.85
      const transcript = 'a b c d e f g h i m n o p q r s t';
      final ctx = buildCtx(twentyWords, transcript);
      expect(ctx.matchRate, lessThan(0.90));
      final result = detectNearCompletion(ctx);
      expect(result.triggered, isFalse);
      expect(result.description, contains('<90%'));
    });

    test('matchRate=95% + 末尾 3/5（漏末尾 2 词） → 不触发', () {
      // 漏末尾 r 和 s：matchRate = 18/20 = 0.90
      // 末尾 5 词 (p q r s t) 命中 3 个（p q t）
      const transcript = 'a b c d e f g h i j k l m n o p q t';
      final ctx = buildCtx(twentyWords, transcript);
      expect(ctx.matchRate, greaterThanOrEqualTo(0.90));
      final result = detectNearCompletion(ctx);
      expect(result.triggered, isFalse);
      expect(result.description, contains('命中3<4'));
    });

    test('无匹配（空 transcript） → 不触发', () {
      final ctx = buildCtx(twentyWords, '');
      final result = detectNearCompletion(ctx);
      expect(result.triggered, isFalse);
      expect(result.description, contains('无匹配'));
    });

    test('matchRate 刚好 0.90 边界 → 触发（含等号）', () {
      // 漏前段 2 词 (a b)：matchRate = 18/20 = 0.90
      // 末尾 5/5 命中
      const transcript = 'c d e f g h i j k l m n o p q r s t';
      final ctx = buildCtx(twentyWords, transcript);
      expect(ctx.matchRate, closeTo(0.90, 0.001));
      final result = detectNearCompletion(ctx);
      expect(result.triggered, isTrue);
    });

    test('短文本（4 词），全部匹配 → 触发（末尾词数不足时用 effective 大小）', () {
      // 4 词全部匹配，末尾 size=min(5,4)=4，需要命中 min(4,4)=4
      final ctx = buildCtx('one two three four', 'one two three four');
      final result = detectNearCompletion(ctx);
      expect(result.triggered, isTrue);
    });

    test('短文本（4 词），漏 1 词且不在末尾 → matchRate=75% 不触发', () {
      // 漏第 1 词，matchRate=3/4=0.75 < 0.90 → 不触发
      final ctx = buildCtx('one two three four', 'two three four');
      expect(ctx.matchRate, lessThan(0.90));
      final result = detectNearCompletion(ctx);
      expect(result.triggered, isFalse);
    });

    test('参数化：minMatchRate=0.95 时 90% 不触发', () {
      const transcript = 'a b c d e f g h i j l m n o p q r t';
      final ctx = buildCtx(twentyWords, transcript);
      final result = detectNearCompletion(ctx, minMatchRate: 0.95);
      expect(result.triggered, isFalse);
    });

    test('参数化：minTailHits=5 时 4/5 不触发', () {
      const transcript = 'a b c d e f g h i j l m n o p q r t';
      final ctx = buildCtx(twentyWords, transcript);
      final result = detectNearCompletion(ctx, minTailHits: 5);
      expect(result.triggered, isFalse);
    });

    test('参数化：自定义 triggerDuration', () {
      final ctx = buildCtx(twentyWords, twentyWords);
      final result = detectNearCompletion(
        ctx,
        triggerDuration: const Duration(milliseconds: 2500),
      );
      expect(result.triggered, isTrue);
      expect(result.threshold, const Duration(milliseconds: 2500));
    });
  });

  // ================================================================
  // 动态兜底边界测试（2026-05-18）
  // ================================================================
  group('computeRetellDynamicFallback 边界条件', () {
    test('ratio 刚好等于 0.95 → 走 ≥0.95 档（含等号）', () {
      // ref=30s（cap=30s, scale=1.0）, speedFactor=1.3, adjusted=39s
      // voiced=37050ms → ratio 严格 = 0.95
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 37050),
          referenceDuration: const Duration(seconds: 30),
        ),
        const Duration(seconds: 6),
      );
    });

    test('ratio 刚好等于 0.75 → 走 ≥0.75 档 = cap', () {
      // ref=30s, adjusted=39s, voiced=29250 → ratio=0.75
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 29250),
          referenceDuration: const Duration(seconds: 30),
        ),
        const Duration(seconds: 30),
      );
    });

    test('ratio 略低于 0.75（0.749） → 走 <0.75 档 = cap', () {
      // adjusted=39000, voiced=29220 → ratio≈0.7492
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 29220),
          referenceDuration: const Duration(seconds: 30),
        ),
        const Duration(seconds: 30),
      );
    });

    test('matchRate 刚好等于 0.8 → 动态兜底生效（非截断）', () {
      // ref=30s, ratio=0.95 → 6s
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 37050),
          referenceDuration: const Duration(seconds: 30),
          matchRate: 0.8,
        ),
        const Duration(seconds: 6),
      );
    });

    test('ref 刚好等于上限 30s → cap = 30s', () {
      expect(
        computeRetellDynamicFallback(
          voicedDuration: Duration.zero,
          referenceDuration: const Duration(seconds: 30),
        ),
        const Duration(seconds: 30),
      );
    });

    test('ref 刚好等于下限 5s → cap = 5s', () {
      expect(
        computeRetellDynamicFallback(
          voicedDuration: Duration.zero,
          referenceDuration: const Duration(seconds: 5),
        ),
        const Duration(seconds: 5),
      );
    });

    test('ref 略小于下限（4s） → cap clamp 到 5s', () {
      expect(
        computeRetellDynamicFallback(
          voicedDuration: Duration.zero,
          referenceDuration: const Duration(seconds: 4),
        ),
        const Duration(seconds: 5),
      );
    });

    test('ref 介于 20s 和 30s（25s）→ cap=25s, scale=25/30', () {
      // capMs=25000, scale=25000/30000=0.833
      // speedFactor=1.3 (>20s), adjusted=32.5s, voiced=30875 → ratio=0.95
      // → 6000×0.833=5000ms → 不被下限抬高，恰为下限
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 30875),
          referenceDuration: const Duration(seconds: 25),
        ),
        const Duration(seconds: 5),
      );
    });

    test(
      'voicedDuration > adjustedDuration（用户说得比原文更长） → ratio > 1, 仍走 ≥0.95 档',
      () {
        // ref=30s, adjusted=39s, voiced=50s → ratio≈1.28
        expect(
          computeRetellDynamicFallback(
            voicedDuration: const Duration(seconds: 50),
            referenceDuration: const Duration(seconds: 30),
          ),
          const Duration(seconds: 6),
        );
      },
    );

    test('voiced 为 0 但 matchRate >= 0.8 → ratio=0 走 <0.75 = cap', () {
      expect(
        computeRetellDynamicFallback(
          voicedDuration: Duration.zero,
          referenceDuration: const Duration(seconds: 30),
          matchRate: 0.9,
        ),
        const Duration(seconds: 30),
      );
    });

    test('完整最短下限保证：ratio=0.95 + ref=5s → 1s 计算结果被抬到 5s', () {
      // capMs=5000, scale=0.167
      // 6000×0.167≈1000ms < 5000ms → 抬到 5s
      expect(
        computeRetellDynamicFallback(
          voicedDuration: const Duration(milliseconds: 5225),
          referenceDuration: const Duration(seconds: 5),
        ),
        const Duration(seconds: 5),
      );
    });
  });
}
