import 'package:loop_back/models/sentence.dart';
import 'package:loop_back/models/word_timestamp.dart';
import 'package:loop_back/utils/word_timestamp_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Sentence sentence(int index, int startMs, int endMs) => Sentence(
    index: index,
    text: 's$index',
    startTime: Duration(milliseconds: startMs),
    endTime: Duration(milliseconds: endMs),
  );

  WordTimestamp word(String text, int startMs, int endMs) => WordTimestamp(
    word: text,
    startTime: Duration(milliseconds: startMs),
    endTime: Duration(milliseconds: endMs),
  );

  group('syncWordTimestampsToSentenceBounds', () {
    test('首词 start 与末词 end 对齐句子边界，中间词不变', () {
      final sentences = [sentence(0, 0, 1000)];
      final words = [
        word('a', 100, 300),
        word('b', 350, 600),
        word('c', 650, 900),
      ];

      final result = syncWordTimestampsToSentenceBounds(sentences, words);

      expect(result, hasLength(3));
      // 首词 start 对齐到句子 start。
      expect(result[0].startTime, Duration.zero);
      expect(result[0].endTime, const Duration(milliseconds: 300));
      // 中间词完全不变。
      expect(result[1].startTime, const Duration(milliseconds: 350));
      expect(result[1].endTime, const Duration(milliseconds: 600));
      // 末词 end 对齐到句子 end。
      expect(result[2].startTime, const Duration(milliseconds: 650));
      expect(result[2].endTime, const Duration(milliseconds: 1000));
    });

    test('右拖句子 end（句长扩大）：末词 end 跟随', () {
      // 原句 [0,900]，end 右拖到 1200。
      final sentences = [sentence(0, 0, 1200)];
      final words = [word('a', 100, 400), word('b', 450, 900)];

      final result = syncWordTimestampsToSentenceBounds(sentences, words);

      expect(result.last.endTime, const Duration(milliseconds: 1200));
    });

    test('左拖句子 start（句长扩大）：首词 start 跟随', () {
      // start 左拖到 -? 用 200 表示原句首词在 500 开始，start 移到 200。
      final sentences = [sentence(0, 200, 1000)];
      final words = [word('a', 500, 700), word('b', 750, 950)];

      final result = syncWordTimestampsToSentenceBounds(sentences, words);

      expect(result.first.startTime, const Duration(milliseconds: 200));
    });

    test('被删除区间的词（中点落在句间静音）被丢弃', () {
      // 两句之间 [1000,2000] 是静音；中点在该区间的词应被丢弃。
      final sentences = [sentence(0, 0, 1000), sentence(1, 2000, 3000)];
      final words = [
        word('a', 100, 800), // 中点 450 → 句0
        word('gap', 1200, 1800), // 中点 1500 → 静音，丢弃
        word('b', 2100, 2800), // 中点 2450 → 句1
      ];

      final result = syncWordTimestampsToSentenceBounds(sentences, words);

      expect(result.map((w) => w.word), ['a', 'b']);
    });

    test('合并后单句跨越原两句的词：仍只对齐合并句的首尾', () {
      // 合并后句子 [0,4000] 覆盖原本两句的全部词。
      final sentences = [sentence(0, 0, 4000)];
      final words = [
        word('a', 100, 900),
        word('b', 2100, 2900),
        word('c', 3100, 3900),
      ];

      final result = syncWordTimestampsToSentenceBounds(sentences, words);

      expect(result, hasLength(3));
      expect(result.first.startTime, Duration.zero);
      expect(result.last.endTime, const Duration(milliseconds: 4000));
      // 中间词 b 完全不变。
      expect(result[1].startTime, const Duration(milliseconds: 2100));
      expect(result[1].endTime, const Duration(milliseconds: 2900));
    });

    test('相邻句首尾相接（touching）时词不重复归属', () {
      // 句0 [0,1000)，句1 [1000,2000)；边界词中点恰在 1000 应归句1。
      final sentences = [sentence(0, 0, 1000), sentence(1, 1000, 2000)];
      final words = [
        word('a', 200, 400),
        word('edge', 800, 1200), // 中点 1000 → 句1
        word('b', 1500, 1800),
      ];

      final result = syncWordTimestampsToSentenceBounds(sentences, words);

      // 总数不增（无重复），edge 归到句1。
      expect(result, hasLength(3));
      expect(result.map((w) => w.word), ['a', 'edge', 'b']);
    });

    test('空词数组返回空', () {
      final sentences = [sentence(0, 0, 1000)];
      expect(syncWordTimestampsToSentenceBounds(sentences, const []), isEmpty);
    });

    test('单词同时为首尾时 start 和 end 都对齐', () {
      final sentences = [sentence(0, 0, 1000)];
      final words = [word('only', 300, 700)];

      final result = syncWordTimestampsToSentenceBounds(sentences, words);

      expect(result, hasLength(1));
      expect(result.first.startTime, Duration.zero);
      expect(result.first.endTime, const Duration(milliseconds: 1000));
    });
  });
}
