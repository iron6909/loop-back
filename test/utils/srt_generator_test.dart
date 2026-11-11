import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/services/subtitle_parser.dart';
import 'package:loop_back/utils/srt_generator.dart';

void main() {
  group('generateSrtContent', () {
    test('空列表返回空字符串', () {
      expect(generateSrtContent([]), '');
    });

    test('单句生成正确格式', () {
      final sentences = [
        TranscriptSentence(
          text: 'Hello world',
          startTime: const Duration(seconds: 1, milliseconds: 500),
          endTime: const Duration(seconds: 4),
        ),
      ];
      final result = generateSrtContent(sentences);
      expect(result, '1\n00:00:01,500 --> 00:00:04,000\nHello world\n');
    });

    test('多句按顺序编号', () {
      final sentences = [
        TranscriptSentence(
          text: 'First sentence.',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 2),
        ),
        TranscriptSentence(
          text: 'Second sentence.',
          startTime: const Duration(seconds: 2, milliseconds: 500),
          endTime: const Duration(seconds: 5),
        ),
        TranscriptSentence(
          text: 'Third sentence.',
          startTime: const Duration(seconds: 5, milliseconds: 100),
          endTime: const Duration(seconds: 8, milliseconds: 200),
        ),
      ];
      final result = generateSrtContent(sentences);
      final lines = result.split('\n');

      // 检查序号
      expect(lines[0], '1');
      expect(lines[4], '2');
      expect(lines[8], '3');

      // 检查时间轴
      expect(lines[1], '00:00:00,000 --> 00:00:02,000');
      expect(lines[5], '00:00:02,500 --> 00:00:05,000');
      expect(lines[9], '00:00:05,100 --> 00:00:08,200');
    });

    test('时间超过 1 小时格式正确', () {
      final sentences = [
        TranscriptSentence(
          text: 'Late in the audio.',
          startTime: const Duration(
            hours: 1,
            minutes: 23,
            seconds: 45,
            milliseconds: 678,
          ),
          endTime: const Duration(hours: 1, minutes: 23, seconds: 50),
        ),
      ];
      final result = generateSrtContent(sentences);
      expect(result, contains('01:23:45,678 --> 01:23:50,000'));
    });

    test('特殊字符不破坏格式', () {
      final sentences = [
        TranscriptSentence(
          text: 'He said "hello" & she <replied>.',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 3),
        ),
      ];
      final result = generateSrtContent(sentences);
      expect(result, contains('He said "hello" & she <replied>.'));
    });

    test('句子之间有空行分隔', () {
      final sentences = [
        TranscriptSentence(
          text: 'A',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
        ),
        TranscriptSentence(
          text: 'B',
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 2),
        ),
      ];
      final result = generateSrtContent(sentences);
      // 第一个块末尾换行 + 空行 + 第二个块开始
      expect(result, contains('A\n\n2\n'));
    });
  });

  group('TranscriptSentence.fromJson', () {
    test('正确解析 JSON（后端单位为秒）', () {
      final json = {'text': 'Hello', 'startTime': 1.5, 'endTime': 4.0};
      final sentence = TranscriptSentence.fromJson(json);
      expect(sentence.text, 'Hello');
      expect(sentence.startTime, const Duration(milliseconds: 1500));
      expect(sentence.endTime, const Duration(milliseconds: 4000));
    });

    test('浮点数时间值正确舍入', () {
      final json = {'text': 'Test', 'startTime': 1.5007, 'endTime': 4.0003};
      final sentence = TranscriptSentence.fromJson(json);
      expect(sentence.startTime, const Duration(milliseconds: 1501));
      expect(sentence.endTime, const Duration(milliseconds: 4000));
    });

    test('整数秒值正确转换', () {
      final json = {'text': 'Test', 'startTime': 0, 'endTime': 120};
      final sentence = TranscriptSentence.fromJson(json);
      expect(sentence.startTime, Duration.zero);
      expect(sentence.endTime, const Duration(minutes: 2));
    });
  });

  group('端到端：后端 JSON → SRT → SubtitleParser', () {
    test('模拟真实后端数据完整往返', () async {
      // 1. 模拟后端返回的 sentences JSON（时间单位为秒）
      final backendSentences = [
        {'text': 'Hello world.', 'startTime': 0, 'endTime': 4.24},
        {'text': 'How are you?', 'startTime': 4.96, 'endTime': 20.855},
        {'text': 'I am fine.', 'startTime': 21.095, 'endTime': 39.52},
      ];

      // 2. fromJson 解析
      final transcriptSentences = backendSentences
          .map((j) => TranscriptSentence.fromJson(j))
          .toList();

      // 验证解析后的 Duration 正确
      expect(transcriptSentences[0].startTime, Duration.zero);
      expect(
        transcriptSentences[0].endTime,
        const Duration(milliseconds: 4240),
      );
      expect(
        transcriptSentences[1].startTime,
        const Duration(milliseconds: 4960),
      );
      expect(
        transcriptSentences[2].endTime,
        const Duration(milliseconds: 39520),
      );

      // 3. 生成 SRT 内容
      final srtContent = generateSrtContent(transcriptSentences);

      // 验证 SRT 时间戳
      expect(srtContent, contains('00:00:00,000 --> 00:00:04,240'));
      expect(srtContent, contains('00:00:04,960 --> 00:00:20,855'));
      expect(srtContent, contains('00:00:21,095 --> 00:00:39,520'));

      // 4. 写入临时文件
      final tmpFile = File('${Directory.systemTemp.path}/test_roundtrip.srt');
      await tmpFile.writeAsString(srtContent);

      try {
        // 5. SubtitleParser 解析回 Sentence
        final parsed = await SubtitleParser.parseSubtitle(tmpFile.path);

        expect(parsed.length, 3);

        // 6. 验证时间戳完整往返正确
        expect(parsed[0].text, 'Hello world.');
        expect(parsed[0].startTime, Duration.zero);
        expect(parsed[0].endTime, const Duration(milliseconds: 4240));
        expect(parsed[0].duration, const Duration(milliseconds: 4240));

        expect(parsed[1].text, 'How are you?');
        expect(parsed[1].startTime, const Duration(milliseconds: 4960));
        expect(parsed[1].endTime, const Duration(milliseconds: 20855));

        expect(parsed[2].text, 'I am fine.');
        expect(parsed[2].startTime, const Duration(milliseconds: 21095));
        expect(parsed[2].endTime, const Duration(milliseconds: 39520));

        // 确保没有 0 时长句子
        for (final s in parsed) {
          expect(
            s.duration,
            greaterThan(Duration.zero),
            reason: 'Sentence "${s.text}" has zero duration',
          );
        }
      } finally {
        await tmpFile.delete();
      }
    });
  });
}
