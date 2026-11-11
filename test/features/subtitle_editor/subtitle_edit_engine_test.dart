import 'package:loop_back/features/subtitle_editor/subtitle_edit_engine.dart';
import 'package:loop_back/models/sentence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const engine = SubtitleEditEngine();

  List<Sentence> sentences() => [
    Sentence(
      index: 0,
      text: 'Hello world.',
      startTime: Duration.zero,
      endTime: const Duration(seconds: 2),
    ),
    Sentence(
      index: 1,
      text: 'Next sentence.',
      startTime: const Duration(seconds: 2),
      endTime: const Duration(seconds: 4),
    ),
    Sentence(
      index: 2,
      text: 'Last one.',
      startTime: const Duration(seconds: 4),
      endTime: const Duration(seconds: 6),
    ),
  ];

  group('SubtitleEditEngine', () {
    test('mergeWithNext 合并文本和时间并重排 index', () {
      final result = engine.mergeWithNext(sentences(), 0);

      expect(result, hasLength(2));
      expect(result[0].index, 0);
      expect(result[0].text, 'Hello world. Next sentence.');
      expect(result[0].startTime, Duration.zero);
      expect(result[0].endTime, const Duration(seconds: 4));
      expect(result[1].index, 1);
      expect(result[1].text, 'Last one.');
    });

    test('mergeWithNext 最后一句不变', () {
      final input = sentences();
      final result = engine.mergeWithNext(input, 2);

      expect(result, same(input));
    });

    test('deleteSentence 删除句子并重排 index', () {
      final result = engine.deleteSentence(sentences(), 1);

      expect(result, hasLength(2));
      expect(result[0].index, 0);
      expect(result[0].text, 'Hello world.');
      expect(result[1].index, 1);
      expect(result[1].text, 'Last one.');
    });

    test('deleteSentence 不允许删除到空字幕', () {
      final input = [
        Sentence(
          index: 0,
          text: 'Only one.',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
        ),
      ];

      final result = engine.deleteSentence(input, 0);

      expect(result, same(input));
    });

    test('splitSentence 拆成两句并设置文本/时间，重排 index', () {
      final result = engine.splitSentence(
        sentences(),
        0,
        firstText: 'Hello',
        firstEnd: const Duration(seconds: 1),
        secondText: 'world.',
        secondStart: const Duration(seconds: 1),
      );

      expect(result, hasLength(4));
      expect(result[0].index, 0);
      expect(result[0].text, 'Hello');
      expect(result[0].startTime, Duration.zero);
      expect(result[0].endTime, const Duration(seconds: 1));
      expect(result[1].index, 1);
      expect(result[1].text, 'world.');
      expect(result[1].startTime, const Duration(seconds: 1));
      expect(result[1].endTime, const Duration(seconds: 2));
      expect(result[2].index, 2);
      expect(result[2].text, 'Next sentence.');
      expect(result[3].index, 3);
      expect(result[3].text, 'Last one.');
    });

    test('splitSentence 越界返回原列表', () {
      final input = sentences();
      expect(
        engine.splitSentence(
          input,
          5,
          firstText: 'a',
          firstEnd: Duration.zero,
          secondText: 'b',
          secondStart: Duration.zero,
        ),
        same(input),
      );
    });
  });
}
