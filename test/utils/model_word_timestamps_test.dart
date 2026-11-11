/// 模型词时间戳与按句估算时间线的合并。
///
/// 只有逐句词序列与文本完全一致才采用模型时间；缺失、词面对不上或边界错位的
/// 句子必须保留估算值，并让整份来源如实落在 estimated / mixed。
library;

import 'package:loop_back/models/audio_item.dart';
import 'package:loop_back/models/sentence.dart';
import 'package:loop_back/services/speech/speech_transcription_client.dart';
import 'package:loop_back/utils/model_word_timestamps.dart';
import 'package:flutter_test/flutter_test.dart';

Sentence _sentence(String text, int startMs, int endMs) => Sentence(
  index: 0,
  text: text,
  startTime: Duration(milliseconds: startMs),
  endTime: Duration(milliseconds: endMs),
);

SpeechTranscriptWord _word(String word, int startMs, int endMs) =>
    SpeechTranscriptWord(
      word: word,
      start: startMs / 1000,
      end: endMs / 1000,
    );

void main() {
  test('整份句子都能对上模型词时保留模型时间戳并标记 model', () {
    final result = combineModelWordTimestamps(
      sentences: [
        _sentence('Hello world.', 0, 1000),
        _sentence('Second line.', 1000, 2200),
      ],
      modelWords: [
        _word('Hello', 100, 500),
        _word('world.', 520, 980),
        _word('Second', 1100, 1600),
        _word('line.', 1620, 2180),
      ],
    );

    expect(result.source, TranscriptWordTimingSource.model);
    expect(result.words.map((word) => word.word), [
      'Hello',
      'world.',
      'Second',
      'line.',
    ]);
    expect(result.words.first.startTime, const Duration(milliseconds: 100));
    expect(result.words.last.endTime, const Duration(milliseconds: 2180));
  });

  test('句子词面对不上时该句保留估算值，整份标记 mixed', () {
    final result = combineModelWordTimestamps(
      sentences: [
        _sentence('Hello world.', 0, 1000),
        _sentence('Totally different.', 1000, 2200),
      ],
      modelWords: [
        _word('Hello', 100, 500),
        _word('world.', 520, 980),
        _word('Unrelated', 1100, 1600),
        _word('speech.', 1620, 2180),
      ],
    );

    expect(result.source, TranscriptWordTimingSource.mixed);
    // 第一句用模型时间，第二句退回句内按字数分配的估算。
    expect(result.words.first.startTime, const Duration(milliseconds: 100));
    final estimated = result.words.skip(2).toList();
    expect(estimated.first.startTime, const Duration(milliseconds: 1000));
    expect(estimated.last.endTime, const Duration(milliseconds: 2200));
  });

  test('没有可用模形词时整份回退估算并标记 estimated', () {
    final result = combineModelWordTimestamps(
      sentences: [_sentence('Hello world.', 0, 1000)],
      modelWords: const [],
    );

    expect(result.source, TranscriptWordTimingSource.estimated);
    expect(result.words.map((word) => word.word), ['Hello', 'world.']);
    expect(result.words.first.startTime, Duration.zero);
    expect(result.words.last.endTime, const Duration(milliseconds: 1000));
  });

  test('模型词起点落在句子区间外时不借用错位时间', () {
    final result = combineModelWordTimestamps(
      sentences: [_sentence('Hello world.', 1000, 2000)],
      modelWords: [
        _word('Hello', 120, 480),
        _word('world.', 500, 960),
      ],
    );

    expect(result.source, TranscriptWordTimingSource.estimated);
    expect(result.words.first.startTime, const Duration(milliseconds: 1000));
  });

  test('空句子列表不产生词时间戳', () {
    final result = combineModelWordTimestamps(
      sentences: const [],
      modelWords: [_word('Hello', 0, 500)],
    );

    expect(result.words, isEmpty);
    expect(result.source, TranscriptWordTimingSource.estimated);
  });
}
