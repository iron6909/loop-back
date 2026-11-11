/// SavedTextIndex 构建逻辑单测
///
/// 覆盖：key 统一归一化、单词/词组分桶、词数集合、空 key 跳过、isEmpty。
library;

import 'package:loop_back/utils/saved_text_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SavedTextIndex', () {
    test('empty 构造与 isEmpty', () {
      const index = SavedTextIndex.empty();
      expect(index.isEmpty, isTrue);
      expect(index.singleWords, isEmpty);
      expect(index.phrases, isEmpty);
      expect(index.phraseWordCounts, isEmpty);
    });

    test('key 经 normalizeWord 归一化（大小写/边缘标点/弯撇号/多空格）', () {
      final index = SavedTextIndex.build(
        savedWords: {'Hello', 'e.g.', "DOGS’"},
        savedPhrases: {'"Figure  Out"'},
      );
      expect(index.singleWords, {'hello', 'e.g', "dogs'"});
      expect(index.phrases, {'figure out'});
      expect(index.phraseWordCounts, {2});
    });

    test('两张表的 key 按词数统一分桶（意群单词进 singleWords）', () {
      final index = SavedTextIndex.build(
        savedWords: {'give up'},
        savedPhrases: {'beautiful', 'over the lazy dog'},
      );
      expect(index.singleWords, {'beautiful'});
      expect(index.phrases, {'give up', 'over the lazy dog'});
      expect(index.phraseWordCounts, {2, 4});
    });

    test('归一化后为空的 key 被跳过', () {
      final index = SavedTextIndex.build(
        savedWords: {'...', '—'},
        savedPhrases: {'  '},
      );
      expect(index.isEmpty, isTrue);
    });
  });
}
