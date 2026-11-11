import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/sentence.dart';
import 'package:loop_back/utils/paragraph_grouping.dart';

/// 辅助：用 (startMs, endMs) 创建带句间空白的句子（不连续）
Sentence _s(int idx, int startMs, int endMs) => Sentence(
  index: idx,
  text: 'Sentence $idx',
  startTime: Duration(milliseconds: startMs),
  endTime: Duration(milliseconds: endMs),
);

/// 辅助函数：创建指定时长的句子列表
List<Sentence> _makeSentences(List<int> durationsMs) {
  final sentences = <Sentence>[];
  var start = 0;
  for (var i = 0; i < durationsMs.length; i++) {
    sentences.add(
      Sentence(
        index: i,
        text: 'Sentence $i',
        startTime: Duration(milliseconds: start),
        endTime: Duration(milliseconds: start + durationsMs[i]),
      ),
    );
    start += durationsMs[i];
  }
  return sentences;
}

/// 辅助函数：计算段落总时长（毫秒）
int _paragraphDurationMs(List<Sentence> paragraph) {
  if (paragraph.isEmpty) return 0;
  return paragraph.last.endTime.inMilliseconds -
      paragraph.first.startTime.inMilliseconds;
}

void main() {
  group('groupSentencesIntoParagraphs', () {
    test('空列表返回空', () {
      final result = groupSentencesIntoParagraphs(
        [],
        const Duration(seconds: 30),
      );
      expect(result, isEmpty);
    });

    test('单句返回单段', () {
      final sentences = _makeSentences([5000]);
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      expect(result, hasLength(1));
      expect(result[0], hasLength(1));
      expect(result[0][0].index, 0);
    });

    test('总时长小于目标时长 → 单段', () {
      final sentences = _makeSentences([5000, 5000, 5000]); // 15s < 30s
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      expect(result, hasLength(1));
      expect(result[0], hasLength(3));
    });

    test('正常分段：2分钟音频 target=30s → ~4 段', () {
      // 20 句 × 6s = 120s，target=30s → 约 4 段
      final sentences = _makeSentences(List.filled(20, 6000));
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      expect(result.length, inInclusiveRange(3, 5));
      // 所有句子都包含
      final allSentences = result.expand((g) => g).toList();
      expect(allSentences.length, 20);
    });

    test('均匀性：各段时长差距尽量小', () {
      // 12 句 × 10s = 120s，target=30s → 4 段（完美均分）
      final sentences = _makeSentences(List.filled(12, 10000));
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      expect(result.length, 4);
      // 每段应为 3 句 × 10s = 30s
      for (final group in result) {
        expect(group.length, 3);
        expect(_paragraphDurationMs(group), 30000);
      }
    });

    test('2:05 音频不产生极短末段', () {
      // 25 句 × 5s = 125s，target=30s
      final sentences = _makeSentences(List.filled(25, 5000));
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      // 不应有极短段（<10s）
      for (final group in result) {
        final durationMs = _paragraphDurationMs(group);
        expect(
          durationMs,
          greaterThanOrEqualTo(10000),
          reason: '段落时长 ${durationMs}ms 过短',
        );
      }
    });

    test('单句超长 > target 独立成段', () {
      final sentences = _makeSentences([40000, 5000, 5000, 5000]);
      // 总时长 55s，target=30s
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      // 第一句 40s 应独立成段
      expect(result.first.length, 1);
      expect(result.first[0].index, 0);
    });

    test('不同 target 值产生不同分组数', () {
      // 30 句 × 5s = 150s
      final sentences = _makeSentences(List.filled(30, 5000));

      final result20 = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 20),
      );
      final result60 = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 60),
      );
      // target=20s 应比 target=60s 产生更多段落
      expect(result20.length, greaterThan(result60.length));
    });

    test('所有句子时长相同 → 完美均分', () {
      // 10 句 × 5s = 50s，target=25s → 2 段各 5 句
      final sentences = _makeSentences(List.filled(10, 5000));
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 25),
      );
      expect(result.length, 2);
      expect(result[0].length, 5);
      expect(result[1].length, 5);
    });

    test('句子时长差异较大时仍能合理分组', () {
      // 混合时长：3s, 8s, 2s, 12s, 4s, 7s, 3s, 9s = 48s, target=20s
      final sentences = _makeSentences([
        3000,
        8000,
        2000,
        12000,
        4000,
        7000,
        3000,
        9000,
      ]);
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 20),
      );
      // 应分为 2-3 段
      expect(result.length, inInclusiveRange(2, 3));
      // 所有句子都保留
      final allCount = result.fold<int>(0, (sum, g) => sum + g.length);
      expect(allCount, 8);
    });

    test('保持句子顺序不变', () {
      final sentences = _makeSentences(
        List.filled(15, 4000),
      ); // 60s, target=20s
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 20),
      );
      // 验证索引单调递增
      var prevIndex = -1;
      for (final group in result) {
        for (final s in group) {
          expect(s.index, greaterThan(prevIndex));
          prevIndex = s.index;
        }
      }
    });

    test('两句刚好等于 target → 单段', () {
      final sentences = _makeSentences([15000, 15000]); // 30s = target
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      expect(result, hasLength(1));
      expect(result[0], hasLength(2));
    });

    test('target=90s 大时长分组', () {
      // 60 句 × 3s = 180s，target=90s → 2 段
      final sentences = _makeSentences(List.filled(60, 3000));
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 90),
      );
      expect(result.length, 2);
    });
  });

  group('硬切：长静音处强制断段', () {
    test('单一大空白 ≥ target/2 → 切成两块', () {
      // S0: 0..5s, S1: 35..40s（gap = 30s ≥ 15s）
      final sentences = [_s(0, 0, 5000), _s(1, 35000, 40000)];
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      expect(result.length, 2);
      expect(result[0].single.index, 0);
      expect(result[1].single.index, 1);
    });

    test('gap 恰好 = target/2 → 切（≥ 而非 >）', () {
      // S0: 0..5s, S1: 20..25s（gap = 15s = target/2）
      final sentences = [_s(0, 0, 5000), _s(1, 20000, 25000)];
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      expect(result.length, 2);
    });

    test('gap < target/2 → 不切', () {
      // S0: 0..5s, S1: 19..24s（gap = 14s < 15s）
      final sentences = [_s(0, 0, 5000), _s(1, 19000, 24000)];
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      // 总说话时长 10s < 30s target → 单段
      expect(result.length, 1);
      expect(result[0], hasLength(2));
    });

    test('考试音频典型案例：53s 大空白硬切 + 块内 DP', () {
      // 用户给的实际字幕（毫秒）
      final sentences = [
        _s(0, 896, 9008),
        _s(1, 62144, 69291), // gap(0→1) = 53.1s ≥ 15s ✂
        _s(2, 71139, 77749),
        _s(3, 79485, 99112),
        _s(4, 100955, 113288),
      ];
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      // 结构性断言：S0 必然独立成段（被硬切隔离），S1..S4 不会跨回 S0 这段
      expect(result.length, greaterThanOrEqualTo(2));
      expect(result.first.single.index, 0);
      final tail = result.skip(1).expand((g) => g).toList();
      expect(tail.map((s) => s.index).toList(), [1, 2, 3, 4]);
    });

    test('硬切阈值随 target 缩放：小 target → 更多硬切', () {
      // gap = 8s
      final sentences = [_s(0, 0, 2000), _s(1, 10000, 12000)];

      // target=30s → hardCut=15s，gap=8s 不切
      final r30 = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      expect(r30.length, 1);

      // target=10s → hardCut=5s，gap=8s 切
      final r10 = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 10),
      );
      expect(r10.length, 2);
    });

    test('多个硬切点：3 个 chunk', () {
      // S0..S5，每对相邻句间都有 30s 大空白
      final sentences = [
        _s(0, 0, 2000),
        _s(1, 32000, 34000), // gap=30s ✂
        _s(2, 64000, 66000), // gap=30s ✂
        _s(3, 96000, 98000), // gap=30s ✂
      ];
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      expect(result.length, 4);
      for (var i = 0; i < 4; i++) {
        expect(result[i].single.index, i);
      }
    });

    test('gap 为负（句子重叠）→ 不切，按 DP 处理', () {
      // S0: 0..10s, S1: 8..15s（重叠 2s）
      final sentences = [_s(0, 0, 10000), _s(1, 8000, 15000)];
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      // 不应硬切，sum=17s < target → 单段
      expect(result.length, 1);
    });

    test('target=0（句子级模式）→ 每句一段，不走硬切', () {
      // 含大空白也不应被硬切影响
      final sentences = [
        _s(0, 0, 2000),
        _s(1, 100000, 102000), // 100s 大空白
      ];
      final result = groupSentencesIntoParagraphs(sentences, Duration.zero);
      expect(result.length, 2);
      expect(result[0].single.index, 0);
      expect(result[1].single.index, 1);
    });
  });

  group('边界与异常输入', () {
    test('全部句子完全连续：硬切不触发，结果与现有 DP 等价', () {
      // 用 _makeSentences（连续）vs 自构造（带 0 空白）应等价
      final sentences = _makeSentences(List.filled(12, 10000));
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      expect(result.length, 4);
      for (final group in result) {
        expect(group.length, 3);
      }
    });

    test('两句含恰好 = target/2 的空白', () {
      // 严格大于等于触发硬切（≥）
      final sentences = [_s(0, 0, 5000), _s(1, 35000, 40000)];
      // gap = 30s, target = 60s → hardCut = 30s, 边界恰好触发
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 60),
      );
      expect(result.length, 2);
    });

    test('两句空白比 target/2 小 1ms：不切', () {
      final sentences = [_s(0, 0, 5000), _s(1, 19999, 24999)];
      // gap = 14999ms, target = 30s → hardCut = 15000, 14999 < 15000 不切
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      expect(result.length, 1);
    });

    test('硬切产生的所有 chunk 都是单句', () {
      // 5 句之间全是大空白
      final sentences = [
        for (var i = 0; i < 5; i++) _s(i, i * 100000, i * 100000 + 1000),
      ];
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      expect(result.length, 5);
      for (var i = 0; i < 5; i++) {
        expect(result[i].single.index, i);
      }
    });

    test('硬切后某 chunk 句子总时长 > target → 块内继续 DP', () {
      // 一段 12 句 × 10s 紧密相连（120s），target=30s，块内应 DP 切 4 段
      final dense = [
        for (var i = 0; i < 12; i++) _s(i, i * 10000, i * 10000 + 10000),
      ];
      // 硬切：插入第二个 chunk（与 dense 间隔 60s 大空白）
      final sep = _s(12, 180000, 182000); // gap(11→12) = 60s ≥ 15s ✂
      final sentences = [...dense, sep];

      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      // 至少 5 段：dense 切多段 + 单独的 sep
      expect(result.length, greaterThanOrEqualTo(5));
      expect(result.last.single.index, 12);
      // dense 部分覆盖 S0..S11 顺序保持
      final dp = result.take(result.length - 1).expand((g) => g).toList();
      expect(dp.map((s) => s.index), List.generate(12, (i) => i));
    });

    test('target=1ms（极小）→ hardCut=0，几乎所有 gap 都会触发硬切', () {
      final sentences = [_s(0, 0, 5000), _s(1, 5001, 10000)];
      // gap=1ms, target=1ms → hardCut=0, gap≥0 切
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(milliseconds: 1),
      );
      expect(result.length, 2);
    });

    test('targetDuration 负值视同 ≤ 0：每句一段', () {
      final sentences = [_s(0, 0, 2000), _s(1, 3000, 5000)];
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: -1),
      );
      expect(result.length, 2);
    });

    test('返回结果覆盖所有句子，无遗漏无重复', () {
      final sentences = [
        _s(0, 0, 2000),
        _s(1, 30000, 32000), // gap=28s ≥ 15s ✂
        _s(2, 33000, 35000),
        _s(3, 80000, 82000), // gap=45s ✂
        _s(4, 84000, 86000),
        _s(5, 88000, 90000),
      ];
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      final allIndices = result.expand((g) => g).map((s) => s.index).toList();
      expect(allIndices, List.generate(6, (i) => i));
    });

    test('回归：小空白累积导致单段超 target（用户报告 case）', () {
      // 2018上半年-英译中2 chunk 1 的真实数据（毫秒）：9 句，说话之和 40.8s，
      // 但句间小空白合计 ~5.9s，墙时 46.7s，target=30s。
      // 旧 DP 用"说话之和"算 cost 选 k=1（cost=117 < k=2 的 183），导致单段 46.7s。
      // 新 DP 用墙时算 cost 应选 k=2（cost ≈ 99 < k=1 的 279）。
      final sentences = [
        _s(0, 420, 1992),
        _s(1, 2757, 9060),
        _s(2, 11720, 14886),
        _s(3, 15326, 21151),
        _s(4, 21251, 24538),
        _s(5, 25158, 27595),
        _s(6, 27772, 32977),
        _s(7, 33473, 39528),
        _s(8, 40148, 47127),
      ];
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      // 应至少切成 2 段（不应再出现 46s 单段）
      expect(result.length, greaterThanOrEqualTo(2));
      // 每段墙时应都接近 target 30s（不超过 target 太多）
      for (final p in result) {
        final wallMs =
            p.last.endTime.inMilliseconds - p.first.startTime.inMilliseconds;
        expect(wallMs, lessThan(40000), reason: '段落墙时 ${wallMs}ms 远超 target');
      }
    });

    test('两句 startTime 相同（数据异常）→ 不崩溃，保持顺序', () {
      // 异常字幕：两句开始时间相同
      final sentences = [_s(0, 1000, 2000), _s(1, 1000, 3000)];
      // gap = 1000 - 2000 = -1000，视为不切
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      expect(result.expand((g) => g).map((s) => s.index), [0, 1]);
    });

    test('所有句子时间戳完全重合（极端异常）→ 单段不崩', () {
      // 全部 5 句都是 (1000, 2000)
      final sentences = [for (var i = 0; i < 5; i++) _s(i, 1000, 2000)];
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      // 墙时 = 0 ≤ target → 单段，5 句
      expect(result, hasLength(1));
      expect(result[0], hasLength(5));
    });

    test('endTime < startTime 单句（异常字幕）→ 不崩', () {
      final sentences = [_s(0, 5000, 1000), _s(1, 6000, 8000)];
      // 不抛异常即可
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      // 所有句子都应保留
      expect(result.expand((g) => g).map((s) => s.index), [0, 1]);
    });

    test('硬切阈值仅取整数毫秒（target=3s → hardCut=1500ms）', () {
      // gap=1500ms 恰好 ≥ 1500ms 触发
      final sentences = [_s(0, 0, 1000), _s(1, 2500, 3500)];
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 3),
      );
      expect(result, hasLength(2));
    });

    test('chunk 内 wall-clock 远超 target 时切多段（每段贴近 target）', () {
      // 10 个 1s 句子，每对之间 5s 空白（不触发硬切，因 5 < target/2=15）
      // 总墙时 = 10 + 9*5 = 55s, target=30s → 应切 ~2 段
      final sentences = [
        for (var i = 0; i < 10; i++) _s(i, i * 6000, i * 6000 + 1000),
      ];
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 30),
      );
      expect(result.length, inInclusiveRange(2, 3));
      // 每段墙时不应远超 target
      for (final p in result) {
        final wallMs =
            p.last.endTime.inMilliseconds - p.first.startTime.inMilliseconds;
        expect(
          wallMs,
          lessThanOrEqualTo(40000),
          reason: '段落墙时 ${wallMs}ms 远超 target',
        );
      }
    });

    test('单 chunk 大量句子（性能 / 不漏不重）', () {
      // 100 句紧密相连，target=10s
      final sentences = [
        for (var i = 0; i < 100; i++) _s(i, i * 1000, (i + 1) * 1000),
      ];
      final result = groupSentencesIntoParagraphs(
        sentences,
        const Duration(seconds: 10),
      );
      // 总墙时 100s, target=10s → ~10 段
      expect(result.length, inInclusiveRange(8, 12));
      // 全覆盖、无重复、保序
      final flat = result.expand((g) => g).toList();
      expect(flat.length, 100);
      for (var i = 0; i < 100; i++) {
        expect(flat[i].index, i);
      }
    });
  });
}
