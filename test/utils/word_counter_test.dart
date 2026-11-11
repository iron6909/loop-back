import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/utils/word_counter.dart';
import 'package:loop_back/models/sentence.dart';

void main() {
  group('countWords', () {
    test('空文本返回 0', () {
      expect(countWords(''), 0);
    });

    test('单词 "hello" 返回 1', () {
      expect(countWords('hello'), 1);
    });

    test('多空格 "hello  world" 返回 2', () {
      expect(countWords('hello  world'), 2);
    });

    test('标点不影响词数 "Hello, world!" 返回 2', () {
      expect(countWords('Hello, world!'), 2);
    });

    test('缩写 "don\'t" 算 1 个词', () {
      expect(countWords("don't"), 1);
    });

    test('纯空格返回 0', () {
      expect(countWords('   '), 0);
    });

    test('换行符分隔返回正确词数', () {
      expect(countWords('hello\nworld'), 2);
    });

    test('tab 分隔返回正确词数', () {
      expect(countWords('hello\tworld'), 2);
    });

    test('普通英文句子', () {
      expect(countWords('The quick brown fox jumps over the lazy dog.'), 9);
    });

    test('混合空白字符', () {
      expect(countWords('  hello  \t world \n foo  '), 3);
    });
  });

  group('countWordsInSentences', () {
    test('空列表返回 0', () {
      expect(countWordsInSentences([]), 0);
    });

    test('累加多个句子的词数', () {
      final sentences = [
        Sentence(
          index: 0,
          text: 'Hello world',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
        ),
        Sentence(
          index: 1,
          text: 'This is a test',
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 2),
        ),
      ];
      // 2 + 4 = 6
      expect(countWordsInSentences(sentences), 6);
    });

    test('包含空文本的句子', () {
      final sentences = [
        Sentence(
          index: 0,
          text: 'Hello',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
        ),
        Sentence(
          index: 1,
          text: '',
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 2),
        ),
        Sentence(
          index: 2,
          text: 'World',
          startTime: const Duration(seconds: 2),
          endTime: const Duration(seconds: 3),
        ),
      ];
      // 1 + 0 + 1 = 2
      expect(countWordsInSentences(sentences), 2);
    });
  });
}
