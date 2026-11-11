/// 意群时间戳映射工具单元测试
///
/// 验证 mapSenseGroupTimings 的词匹配、fallback 均分和边界情况。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/word_timestamp.dart';
import 'package:loop_back/utils/sense_group_timing.dart';

/// 构造 WordTimestamp 的辅助方法，时间单位为毫秒
WordTimestamp _word(String text, int startMs, int endMs) {
  return WordTimestamp(
    word: text,
    startTime: Duration(milliseconds: startMs),
    endTime: Duration(milliseconds: endMs),
  );
}

void main() {
  group('mapSenseGroupTimings', () {
    test('三个意群正常匹配', () {
      // 句子: "I have been working very hard"
      final words = [
        _word('I', 0, 100),
        _word('have', 100, 200),
        _word('been', 200, 300),
        _word('working', 300, 400),
        _word('very', 400, 500),
        _word('hard', 500, 600),
      ];
      final chunks = ['I have been', 'working', 'very hard'];

      final timings = mapSenseGroupTimings(
        chunks: chunks,
        words: words,
        sentenceStart: Duration.zero,
        sentenceEnd: const Duration(milliseconds: 600),
        sentenceStartWordIndex: 0,
        sentenceEndWordIndex: 5,
      );

      expect(timings.length, 3);
      // 第一组: I(0) ~ been(300)
      expect(timings[0].start, const Duration(milliseconds: 0));
      expect(timings[0].end, const Duration(milliseconds: 300));
      // 第二组: working(300) ~ working(400)
      expect(timings[1].start, const Duration(milliseconds: 300));
      expect(timings[1].end, const Duration(milliseconds: 400));
      // 第三组: very(400) ~ hard(600)
      expect(timings[2].start, const Duration(milliseconds: 400));
      expect(timings[2].end, const Duration(milliseconds: 600));
    });

    test('单个意群覆盖整句', () {
      final words = [_word('Hello', 1000, 1200), _word('world', 1200, 1500)];
      final chunks = ['Hello world'];

      final timings = mapSenseGroupTimings(
        chunks: chunks,
        words: words,
        sentenceStart: const Duration(milliseconds: 1000),
        sentenceEnd: const Duration(milliseconds: 1500),
        sentenceStartWordIndex: 0,
        sentenceEndWordIndex: 1,
      );

      expect(timings.length, 1);
      expect(timings[0].start, const Duration(milliseconds: 1000));
      expect(timings[0].end, const Duration(milliseconds: 1500));
    });

    test('标点差异不影响匹配（words 含标点，chunk 无标点）', () {
      // 转录引擎返回带标点的词
      final words = [
        _word('Well,', 0, 200),
        _word('I', 200, 300),
        _word('think', 300, 500),
        _word('so.', 500, 700),
      ];
      final chunks = ['Well', 'I think so'];

      final timings = mapSenseGroupTimings(
        chunks: chunks,
        words: words,
        sentenceStart: Duration.zero,
        sentenceEnd: const Duration(milliseconds: 700),
        sentenceStartWordIndex: 0,
        sentenceEndWordIndex: 3,
      );

      expect(timings.length, 2);
      // "Well," 归一化后匹配 "Well"
      expect(timings[0].start, const Duration(milliseconds: 0));
      expect(timings[0].end, const Duration(milliseconds: 200));
      // "I think so." 匹配 "I think so"
      expect(timings[1].start, const Duration(milliseconds: 200));
      expect(timings[1].end, const Duration(milliseconds: 700));
    });

    test('匹配失败时回退到 fallback 均分', () {
      final words = [_word('apple', 0, 300), _word('banana', 300, 600)];
      // 意群文本与 words 完全不同，无法匹配
      final chunks = ['completely different', 'text here'];

      final timings = mapSenseGroupTimings(
        chunks: chunks,
        words: words,
        sentenceStart: const Duration(milliseconds: 1000),
        sentenceEnd: const Duration(milliseconds: 2000),
        sentenceStartWordIndex: 0,
        sentenceEndWordIndex: 1,
      );

      // fallback 按词数均分：第一组 2 词，第二组 2 词 => 各占 500ms
      expect(timings.length, 2);
      expect(timings[0].start, const Duration(milliseconds: 1000));
      expect(timings[0].end, const Duration(milliseconds: 1500));
      expect(timings[1].start, const Duration(milliseconds: 1500));
      expect(timings[1].end, const Duration(milliseconds: 2000));
    });

    test('空意群列表返回空结果', () {
      final words = [_word('hello', 0, 500)];

      final timings = mapSenseGroupTimings(
        chunks: [],
        words: words,
        sentenceStart: Duration.zero,
        sentenceEnd: const Duration(milliseconds: 500),
        sentenceStartWordIndex: 0,
        sentenceEndWordIndex: 0,
      );

      expect(timings, isEmpty);
    });

    test('空 words 列表回退到 fallback', () {
      final chunks = ['some text', 'more text'];

      final timings = mapSenseGroupTimings(
        chunks: chunks,
        words: [],
        sentenceStart: const Duration(milliseconds: 0),
        sentenceEnd: const Duration(milliseconds: 1000),
        sentenceStartWordIndex: 0,
        sentenceEndWordIndex: 0,
      );

      // fallback 均分
      expect(timings.length, 2);
    });

    test('sentenceStartWordIndex 在全文中间的句子', () {
      // 模拟全文有 6 个词，本句从索引 3 开始
      final allWords = [
        _word('First', 0, 100),
        _word('sentence', 100, 200),
        _word('here', 200, 300),
        _word('Second', 300, 400),
        _word('sentence', 400, 500),
        _word('now', 500, 600),
      ];
      final chunks = ['Second sentence', 'now'];

      final timings = mapSenseGroupTimings(
        chunks: chunks,
        words: allWords,
        sentenceStart: const Duration(milliseconds: 300),
        sentenceEnd: const Duration(milliseconds: 600),
        sentenceStartWordIndex: 3,
        sentenceEndWordIndex: 5,
      );

      expect(timings.length, 2);
      expect(timings[0].start, const Duration(milliseconds: 300));
      expect(timings[0].end, const Duration(milliseconds: 500));
      expect(timings[1].start, const Duration(milliseconds: 500));
      expect(timings[1].end, const Duration(milliseconds: 600));
    });

    test('大小写差异不影响匹配', () {
      final words = [
        _word('THE', 0, 200),
        _word('Quick', 200, 400),
        _word('FOX', 400, 600),
      ];
      final chunks = ['the quick', 'fox'];

      final timings = mapSenseGroupTimings(
        chunks: chunks,
        words: words,
        sentenceStart: Duration.zero,
        sentenceEnd: const Duration(milliseconds: 600),
        sentenceStartWordIndex: 0,
        sentenceEndWordIndex: 2,
      );

      expect(timings.length, 2);
      expect(timings[0].start, const Duration(milliseconds: 0));
      expect(timings[0].end, const Duration(milliseconds: 400));
      expect(timings[1].start, const Duration(milliseconds: 400));
      expect(timings[1].end, const Duration(milliseconds: 600));
    });

    test('个别意群匹配不上：静默跳过（零长度占位），其余仍映射真实时间、下标对齐', () {
      // 句子: "I really like it"，但中间插入一个音频里不存在的意群 "and stuff"
      final words = [
        _word('I', 0, 100),
        _word('really', 100, 300),
        _word('like', 300, 400),
        _word('it', 400, 600),
      ];
      final chunks = ['I really', 'and stuff', 'like it'];

      final timings = mapSenseGroupTimings(
        chunks: chunks,
        words: words,
        sentenceStart: Duration.zero,
        sentenceEnd: const Duration(milliseconds: 600),
        sentenceStartWordIndex: 0,
        sentenceEndWordIndex: 3,
      );

      // 下标与 chunks 对齐（3 个）
      expect(timings.length, 3);
      // 匹配上的用真实时间
      expect(timings[0].start, const Duration(milliseconds: 0));
      expect(timings[0].end, const Duration(milliseconds: 300)); // I ~ really
      // 匹配不上的 "and stuff" → 零长度占位（塌缩到前一意群结束点，非播放）
      expect(timings[1].start, timings[1].end);
      expect(timings[1].start, const Duration(milliseconds: 300));
      // 后续意群不受影响，cursor 未被占位意群推进，仍从 like 起
      expect(timings[2].start, const Duration(milliseconds: 300)); // like
      expect(timings[2].end, const Duration(milliseconds: 600)); // it
    });

    test('缩写/撇号差异下匹配不上的意群零长度占位、不抛', () {
      final words = [_word("don't", 0, 200), _word('know', 200, 400)];
      // "dont" 归一化后不含撇号，与 "don't" 归一化后一致 → 可匹配；"maybe" 不存在 → 占位
      final chunks = ['dont know', 'maybe'];

      final timings = mapSenseGroupTimings(
        chunks: chunks,
        words: words,
        sentenceStart: Duration.zero,
        sentenceEnd: const Duration(milliseconds: 400),
        sentenceStartWordIndex: 0,
        sentenceEndWordIndex: 1,
      );

      expect(timings.length, 2);
      expect(timings[0].start, const Duration(milliseconds: 0));
      expect(timings[0].end, const Duration(milliseconds: 400));
      expect(timings[1].start, timings[1].end); // maybe 占位
    });

    test('重复词：cursor 前移避免回头误匹配', () {
      // "the cat the dog"，两个 "the"
      final words = [
        _word('the', 0, 100),
        _word('cat', 100, 200),
        _word('the', 200, 300),
        _word('dog', 300, 400),
      ];
      final chunks = ['the cat', 'the dog'];

      final timings = mapSenseGroupTimings(
        chunks: chunks,
        words: words,
        sentenceStart: Duration.zero,
        sentenceEnd: const Duration(milliseconds: 400),
        sentenceStartWordIndex: 0,
        sentenceEndWordIndex: 3,
      );

      expect(timings.length, 2);
      // 第二个 "the cat" 从第二个 the(200) 起，而非回头匹配第一个 the
      expect(timings[1].start, const Duration(milliseconds: 200));
      expect(timings[1].end, const Duration(milliseconds: 400));
    });

    test('流式部分帧：末意群为前缀，仍映射不抛', () {
      final words = [
        _word('I', 0, 100),
        _word('run', 100, 300),
        _word('fast', 300, 500),
      ];
      // 流式中间帧：medium 尚在生成，末 chunk "fa" 是 "fast" 的前缀（首 token 无法精确匹配）
      final chunks = ['I run', 'fa'];

      final timings = mapSenseGroupTimings(
        chunks: chunks,
        words: words,
        sentenceStart: Duration.zero,
        sentenceEnd: const Duration(milliseconds: 500),
        sentenceStartWordIndex: 0,
        sentenceEndWordIndex: 2,
      );

      // 不崩；"I run" 精确映射，"fa" 匹配不上 → 零长度占位
      expect(timings.length, 2);
      expect(timings[0].start, const Duration(milliseconds: 0));
      expect(timings[0].end, const Duration(milliseconds: 300));
      expect(timings[1].start, timings[1].end);
    });

    test('fallback 按词数比例分配时间', () {
      // 构造一个无法匹配的场景
      final words = [_word('xyz', 0, 100)];
      final chunks = [
        'one', // 1 词
        'two three', // 2 词
      ];

      final timings = mapSenseGroupTimings(
        chunks: chunks,
        words: words,
        sentenceStart: const Duration(milliseconds: 0),
        sentenceEnd: const Duration(milliseconds: 3000),
        sentenceStartWordIndex: 0,
        sentenceEndWordIndex: 0,
      );

      // 总 3 词，3000ms => 第一组 1000ms，第二组 2000ms
      expect(timings.length, 2);
      expect(timings[0].start, const Duration(milliseconds: 0));
      expect(timings[0].end, const Duration(milliseconds: 1000));
      expect(timings[1].start, const Duration(milliseconds: 1000));
      expect(timings[1].end, const Duration(milliseconds: 3000));
    });
  });
}
