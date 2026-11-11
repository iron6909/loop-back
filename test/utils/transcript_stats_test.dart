import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/models/sentence.dart';
import 'package:loop_back/utils/transcript_stats.dart';

/// 纯逻辑测试：统计句子数和单词数
///
/// 由于 getTranscriptStats 依赖文件系统和 path_provider，
/// 这里直接测试统计逻辑本身。
void main() {
  group('字幕统计逻辑', () {
    /// 模拟 getTranscriptStats 中的统计逻辑
    (int, int) computeStats(List<Sentence> sentences) {
      if (sentences.isEmpty) return (0, 0);
      final sentenceCount = sentences.length;
      int wordCount = 0;
      for (final sentence in sentences) {
        final words = sentence.text.trim().split(RegExp(r'\s+'));
        wordCount += words.where((w) => w.isNotEmpty).length;
      }
      return (sentenceCount, wordCount);
    }

    test('空列表返回 (0, 0)', () {
      final result = computeStats([]);
      expect(result.$1, 0);
      expect(result.$2, 0);
    });

    test('单句统计正确', () {
      final sentences = [
        Sentence(
          index: 0,
          text: 'Hello world',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 2),
        ),
      ];
      final result = computeStats(sentences);
      expect(result.$1, 1);
      expect(result.$2, 2);
    });

    test('多句统计正确', () {
      final sentences = [
        Sentence(
          index: 0,
          text: 'Hello world',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 2),
        ),
        Sentence(
          index: 1,
          text: 'This is a test sentence',
          startTime: const Duration(seconds: 2),
          endTime: const Duration(seconds: 5),
        ),
        Sentence(
          index: 2,
          text: 'One',
          startTime: const Duration(seconds: 5),
          endTime: const Duration(seconds: 6),
        ),
      ];
      final result = computeStats(sentences);
      expect(result.$1, 3);
      expect(result.$2, 8); // 2 + 5 + 1
    });

    test('处理多余空白', () {
      final sentences = [
        Sentence(
          index: 0,
          text: '  Hello   world  ',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 2),
        ),
      ];
      final result = computeStats(sentences);
      expect(result.$1, 1);
      expect(result.$2, 2);
    });

    test('处理空文本句子', () {
      final sentences = [
        Sentence(
          index: 0,
          text: '',
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
        ),
        Sentence(
          index: 1,
          text: 'Hello',
          startTime: const Duration(seconds: 1),
          endTime: const Duration(seconds: 2),
        ),
      ];
      final result = computeStats(sentences);
      expect(result.$1, 2);
      expect(result.$2, 1); // 空文本产生 0 个有效单词
    });
  });

  group('getTranscriptStatsFromSrt（从 SRT 字符串统计）', () {
    test('多句 SRT 统计句数/词数', () async {
      const srt =
          '1\n00:00:00,000 --> 00:00:02,000\nHello world\n\n'
          '2\n00:00:02,000 --> 00:00:05,000\nThis is a test sentence\n';
      final stats = await getTranscriptStatsFromSrt(srt);
      expect(stats.$1, 2);
      expect(stats.$2, 7); // 2 + 5
    });

    test('空字符串返回 (0, 0)', () async {
      final stats = await getTranscriptStatsFromSrt('');
      expect(stats, (0, 0));
    });
  });
}
