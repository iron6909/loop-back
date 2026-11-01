/// 既有页面消费的领域帧；只有经过严格校验的完整结果才带 isFinal。
library;

import '../models/dictionary/dictionary_entry.dart';
import '../models/sense_group_result.dart';
import '../models/sentence_ai_result.dart';

class AiDictionaryStreamFrame {
  const AiDictionaryStreamFrame({required this.entry, required this.isFinal});
  final AiDictionaryEntry entry;
  final bool isFinal;
}

class SentenceTranslationStreamFrame {
  const SentenceTranslationStreamFrame({required this.translation, required this.isFinal});
  final SentenceTranslation translation;
  final bool isFinal;
}

class SentenceAnalysisStreamFrame {
  const SentenceAnalysisStreamFrame({required this.analysis, required this.isFinal});
  final SentenceAnalysis analysis;
  final bool isFinal;
}

class SenseGroupsStreamFrame {
  const SenseGroupsStreamFrame({required this.result, required this.isFinal});
  final SenseGroupResult result;
  final bool isFinal;
}

class SentenceTranslationStreamException implements Exception {
  const SentenceTranslationStreamException();
}

class SentenceAnalysisStreamException implements Exception {
  const SentenceAnalysisStreamException();
}

class SenseGroupsStreamException implements Exception {
  const SenseGroupsStreamException();
}
