import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/word_timestamp.dart';
import 'package:loop_back/utils/word_highlight.dart';

void main() {
  final timestamps = [
    WordTimestamp(
      word: 'hello',
      startTime: const Duration(milliseconds: 100),
      endTime: const Duration(milliseconds: 300),
    ),
    WordTimestamp(
      word: 'world',
      startTime: const Duration(milliseconds: 400),
      endTime: const Duration(milliseconds: 600),
    ),
  ];

  group('resolveActiveWordIndex', () {
    test('按播放位置返回句内词序号并忽略标点', () {
      expect(
        resolveActiveWordIndex(
          text: 'Hello, world!',
          timestamps: timestamps,
          sentenceStart: Duration.zero,
          sentenceEnd: const Duration(seconds: 1),
          position: const Duration(milliseconds: 250),
        ),
        0,
      );
      expect(
        resolveActiveWordIndex(
          text: 'Hello, world!',
          timestamps: timestamps,
          sentenceStart: Duration.zero,
          sentenceEnd: const Duration(seconds: 1),
          position: const Duration(milliseconds: 450),
        ),
        1,
      );
    });

    test('词时间范围含起点、不含终点，词间空隙不高亮', () {
      int? resolve(int milliseconds) => resolveActiveWordIndex(
        text: 'hello world',
        timestamps: timestamps,
        sentenceStart: Duration.zero,
        sentenceEnd: const Duration(seconds: 1),
        position: Duration(milliseconds: milliseconds),
      );

      expect(resolve(100), 0);
      expect(resolve(300), isNull);
      expect(resolve(400), 1);
      expect(resolve(600), isNull);
    });

    test('时间戳词语与句子不完全匹配时整句回退为普通文本', () {
      expect(
        resolveActiveWordIndex(
          text: 'hello brave world',
          timestamps: timestamps,
          sentenceStart: Duration.zero,
          sentenceEnd: const Duration(seconds: 1),
          position: const Duration(milliseconds: 450),
        ),
        isNull,
      );
    });

    test('只采用中点属于当前句子的时间戳', () {
      final adjoiningSentences = [
        WordTimestamp(
          word: 'old',
          startTime: Duration.zero,
          endTime: const Duration(milliseconds: 100),
        ),
        timestamps.first,
        timestamps.last,
      ];

      expect(
        resolveActiveWordIndex(
          text: 'hello world',
          timestamps: adjoiningSentences,
          sentenceStart: const Duration(milliseconds: 100),
          sentenceEnd: const Duration(milliseconds: 700),
          position: const Duration(milliseconds: 450),
        ),
        1,
      );
    });

    test('无效句子区间和无效时间戳不触发高亮', () {
      final invalidTimestamp = WordTimestamp(
        word: 'hello',
        startTime: const Duration(milliseconds: 200),
        endTime: const Duration(milliseconds: 100),
      );

      expect(
        resolveActiveWordIndex(
          text: 'hello',
          timestamps: [invalidTimestamp],
          sentenceStart: Duration.zero,
          sentenceEnd: const Duration(seconds: 1),
          position: const Duration(milliseconds: 250),
        ),
        isNull,
      );
      expect(
        resolveActiveWordIndex(
          text: 'hello',
          timestamps: timestamps,
          sentenceStart: const Duration(seconds: 1),
          sentenceEnd: const Duration(seconds: 1),
          position: const Duration(milliseconds: 250),
        ),
        isNull,
      );
    });
  });
}
