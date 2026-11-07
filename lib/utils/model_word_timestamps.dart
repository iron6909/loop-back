/// 把模型返回的词时间戳并入按句合成的时间线。
///
/// 在线字幕的时间线以片段时间戳为准，词时间戳只在模型确实给了合法词时才采用。
/// 逐句核对：句中模型词的起点要落在句子区间内，规范化后的词序列还要与句子文本
/// 完全一致；否则该句整体保留按字数比例估算的值，避免把错位时间当成精确对齐。
library;

import '../models/audio_item.dart';
import '../models/sentence.dart';
import '../models/word_timestamp.dart';
import '../services/speech/speech_transcription_client.dart';
import 'synthetic_word_timestamps.dart';

/// 句子边界容差：模型与 SRT 都按毫秒取整，边界附近的词仍算本句。
const _boundaryTolerance = Duration(milliseconds: 250);

/// 合并结果：逐词时间线，以及整份字幕的词时间戳来源。
typedef CombinedWordTimings = ({
  List<WordTimestamp> words,
  TranscriptWordTimingSource source,
});

/// 逐句对齐模型词时间戳；对不上的句子用估算值补齐。
///
/// 返回的来源只有三种确定结论：全部句子对齐为 [TranscriptWordTimingSource.model]，
/// 全部回退为 [TranscriptWordTimingSource.estimated]，其余为
/// [TranscriptWordTimingSource.mixed]。未知只属于缺少标记的历史数据，不由此产生。
CombinedWordTimings combineModelWordTimestamps({
  required List<Sentence> sentences,
  required List<SpeechTranscriptWord> modelWords,
}) {
  if (sentences.isEmpty) {
    return (words: const [], source: TranscriptWordTimingSource.estimated);
  }

  final words = <WordTimestamp>[];
  var matchedSentences = 0;
  // 模型词与句子都按时间排序，顺序消费，避免边界词被相邻两句重复计入。
  var nextWordIndex = 0;
  for (final sentence in sentences) {
    final candidates = <SpeechTranscriptWord>[];
    while (nextWordIndex < modelWords.length) {
      final word = modelWords[nextWordIndex];
      final start = Duration(
        microseconds: (word.start * Duration.microsecondsPerSecond).round(),
      );
      if (start >= sentence.endTime) break;
      nextWordIndex++;
      if (start < sentence.startTime - _boundaryTolerance) continue;
      candidates.add(word);
    }
    if (_matchesSentence(sentence, candidates)) {
      matchedSentences++;
      words.addAll(candidates.map(_toWordTimestamp));
    } else {
      words.addAll(generateSyntheticWordTimestamps([sentence]));
    }
  }

  final source = matchedSentences == 0
      ? TranscriptWordTimingSource.estimated
      : matchedSentences == sentences.length
      ? TranscriptWordTimingSource.model
      : TranscriptWordTimingSource.mixed;
  return (words: words, source: source);
}

/// 句子与模型词是否逐词一致：词数相同且规范化后的词面顺序完全一致。
bool _matchesSentence(
  Sentence sentence,
  List<SpeechTranscriptWord> words,
) {
  final expected = _tokens(sentence.text);
  if (expected.isEmpty || expected.length != words.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (expected[i] != _normalizeToken(words[i].word)) return false;
  }
  return true;
}

WordTimestamp _toWordTimestamp(SpeechTranscriptWord word) => WordTimestamp(
  word: word.word,
  startTime: Duration(
    microseconds: (word.start * Duration.microsecondsPerSecond).round(),
  ),
  endTime: Duration(
    microseconds: (word.end * Duration.microsecondsPerSecond).round(),
  ),
);

List<String> _tokens(String text) => [
  for (final match in RegExp(r'\S+').allMatches(text))
    if (_normalizeToken(match.group(0) ?? '').isNotEmpty)
      _normalizeToken(match.group(0) ?? ''),
];

/// 比较词面时忽略大小写与标点，撇号保留（don't 仍是一个词）。
String _normalizeToken(String token) =>
    token.toLowerCase().replaceAll(RegExp(r"[^a-z0-9']"), '');
