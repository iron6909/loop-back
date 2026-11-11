import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/sentence.dart';
import 'package:loop_back/models/word_timestamp.dart';
import 'package:loop_back/utils/synthetic_word_timestamps.dart';

void main() {
  group('generateSyntheticWordTimestamps', () {
    test('按单词字符数分配句子时长', () {
      final words = generateSyntheticWordTimestamps([
        Sentence(
          index: 0,
          text: 'I love Flutter',
          startTime: const Duration(milliseconds: 1000),
          endTime: const Duration(milliseconds: 2300),
        ),
      ]);

      expect(words.map((w) => w.word), ['I', 'love', 'Flutter']);
      expect(words[0].startTime, const Duration(milliseconds: 1000));
      expect(words[0].endTime, const Duration(milliseconds: 1108));
      expect(words[1].startTime, const Duration(milliseconds: 1108));
      expect(words[1].endTime, const Duration(milliseconds: 1542));
      expect(words[2].startTime, const Duration(milliseconds: 1542));
      expect(words[2].endTime, const Duration(milliseconds: 2300));
      expect(words, hasLength(3));
    });

    test('保留词面标点但忽略标点权重', () {
      final words = generateSyntheticWordTimestamps([
        Sentence(
          index: 0,
          text: "Well, I don't know.",
          startTime: Duration.zero,
          endTime: const Duration(milliseconds: 1300),
        ),
      ]);

      expect(words.map((w) => w.word), ['Well,', 'I', "don't", 'know.']);
      expect(words.map((w) => w.endTime.inMilliseconds), [400, 500, 900, 1300]);
    });

    test('多句分别在各自字幕时间范围内生成', () {
      final words = generateSyntheticWordTimestamps([
        Sentence(
          index: 0,
          text: 'Hello world',
          startTime: Duration.zero,
          endTime: const Duration(milliseconds: 1000),
        ),
        Sentence(
          index: 1,
          text: 'Next line',
          startTime: const Duration(milliseconds: 2000),
          endTime: const Duration(milliseconds: 3000),
        ),
      ]);

      expect(words.map((w) => w.word), ['Hello', 'world', 'Next', 'line']);
      expect(words[1].endTime, const Duration(milliseconds: 1000));
      expect(words[2].startTime, const Duration(milliseconds: 2000));
      expect(words.last.endTime, const Duration(milliseconds: 3000));
    });

    test('空文本或无单词句子不生成词级时间戳', () {
      final words = generateSyntheticWordTimestamps([
        Sentence(
          index: 0,
          text: '... ---',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
        ),
      ]);

      expect(words, isEmpty);
    });

    test('零时长句子生成零长度词级时间戳', () {
      final words = generateSyntheticWordTimestamps([
        Sentence(
          index: 0,
          text: 'Too short',
          startTime: const Duration(milliseconds: 500),
          endTime: const Duration(milliseconds: 500),
        ),
      ]);

      expect(words.map((w) => w.startTime.inMilliseconds), [500, 500]);
      expect(words.map((w) => w.endTime.inMilliseconds), [500, 500]);
    });
  });

  group('generateSyntheticWordTimestampsFromSrt', () {
    test('从 SRT 字符串解析并生成可编码的 WordTimestamp JSON', () async {
      const srt =
          '1\n'
          '00:00:01,000 --> 00:00:02,000\n'
          'Hi there\n';

      final words = await generateSyntheticWordTimestampsFromSrt(srt);
      final decoded = decodeWordTimestamps(encodeWordTimestamps(words));

      expect(words.map((w) => w.word), ['Hi', 'there']);
      expect(words.first.startTime, const Duration(milliseconds: 1000));
      expect(words.last.endTime, const Duration(milliseconds: 2000));
      expect(decoded, isNotNull);
      expect(decoded!.map((w) => w.word), ['Hi', 'there']);
    });
  });
}
