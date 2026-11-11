/// StudyPdfExportOptions / applyStudyPdfOptions 单元测试
///
/// 验证内容选项的位掩码/相等性，以及过滤函数对译文、词汇笔记、
/// 句子解析三类内容的独立剔除行为。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/models/pdf_export/study_pdf_data.dart';
import 'package:loop_back/models/pdf_export/study_pdf_options.dart';

/// 构造一份三类内容齐全的测试文档
StudyPdfDocument _fullDocument() {
  return const StudyPdfDocument(
    title: 'Test',
    durationSeconds: 60,
    wordCount: 10,
    paragraphs: [
      [
        StudyPdfSentence(
          index: 0,
          text: 'Hello world.',
          isBookmarked: true,
          savedRanges: [(0, 5)],
          translation: '你好，世界。',
          grammar: '语法说明',
          vocabulary: '词汇说明',
          listening: '听力说明',
          vocabNotes: [
            StudyPdfVocabNote(
              number: 1,
              term: 'hello',
              phonetic: 'həˈloʊ',
              glosses: [StudyPdfGloss(pos: 'int.', text: '你好')],
              ranges: [(0, 5)],
            ),
          ],
          vocabMarkers: [(5, 1)],
        ),
      ],
    ],
  );
}

void main() {
  group('StudyPdfExportOptions', () {
    test('默认全选，bitmask=7', () {
      const options = StudyPdfExportOptions();
      expect(options.includeTranslation, isTrue);
      expect(options.includeVocabNotes, isTrue);
      expect(options.includeAnalysis, isTrue);
      expect(options.includesAll, isTrue);
      expect(options.bitmask, 7);
    });

    test('bitmask 按 译文=1 释义=2 讲解=4 组合', () {
      expect(
        const StudyPdfExportOptions(
          includeTranslation: true,
          includeVocabNotes: false,
          includeAnalysis: false,
        ).bitmask,
        1,
      );
      expect(
        const StudyPdfExportOptions(
          includeTranslation: false,
          includeVocabNotes: true,
          includeAnalysis: false,
        ).bitmask,
        2,
      );
      expect(
        const StudyPdfExportOptions(
          includeTranslation: false,
          includeVocabNotes: false,
          includeAnalysis: true,
        ).bitmask,
        4,
      );
    });

    test('相等性与 copyWith', () {
      const a = StudyPdfExportOptions();
      final b = a.copyWith(includeTranslation: false);
      expect(a, const StudyPdfExportOptions());
      expect(b, isNot(a));
      expect(b.includeVocabNotes, isTrue);
      expect(b.copyWith(includeTranslation: true), a);
    });
  });

  group('applyStudyPdfOptions', () {
    test('全开时返回原文档引用（免拷贝）', () {
      final doc = _fullDocument();
      expect(
        identical(
          applyStudyPdfOptions(doc, const StudyPdfExportOptions()),
          doc,
        ),
        isTrue,
      );
    });

    test('关译文只清 translation，其余保留', () {
      final doc = _fullDocument();
      final result = applyStudyPdfOptions(
        doc,
        const StudyPdfExportOptions(includeTranslation: false),
      );
      final sentence = result.paragraphs.first.first;
      expect(sentence.translation, isNull);
      expect(sentence.vocabNotes, hasLength(1));
      expect(sentence.vocabMarkers, hasLength(1));
      expect(sentence.hasAnalysis, isTrue);
      // 原文档不被修改
      expect(doc.paragraphs.first.first.translation, isNotNull);
    });

    test('关单词释义清 vocabNotes/vocabMarkers，保留收藏下划线', () {
      final doc = _fullDocument();
      final result = applyStudyPdfOptions(
        doc,
        const StudyPdfExportOptions(includeVocabNotes: false),
      );
      final sentence = result.paragraphs.first.first;
      expect(sentence.vocabNotes, isEmpty);
      expect(sentence.vocabMarkers, isEmpty);
      expect(sentence.savedRanges, hasLength(1));
      expect(sentence.translation, isNotNull);
      expect(sentence.hasAnalysis, isTrue);
    });

    test('关句子讲解后 hasAnalysis 为 false', () {
      final doc = _fullDocument();
      final result = applyStudyPdfOptions(
        doc,
        const StudyPdfExportOptions(includeAnalysis: false),
      );
      final sentence = result.paragraphs.first.first;
      expect(sentence.grammar, isNull);
      expect(sentence.vocabulary, isNull);
      expect(sentence.listening, isNull);
      expect(sentence.hasAnalysis, isFalse);
      expect(sentence.translation, isNotNull);
      expect(sentence.vocabNotes, hasLength(1));
    });

    test('全关时保留正文/书签/元信息', () {
      final doc = _fullDocument();
      final result = applyStudyPdfOptions(
        doc,
        const StudyPdfExportOptions(
          includeTranslation: false,
          includeVocabNotes: false,
          includeAnalysis: false,
        ),
      );
      final sentence = result.paragraphs.first.first;
      expect(sentence.text, 'Hello world.');
      expect(sentence.isBookmarked, isTrue);
      expect(result.title, doc.title);
      expect(result.durationSeconds, doc.durationSeconds);
      expect(result.wordCount, doc.wordCount);
      expect(result.sentenceCount, doc.sentenceCount);
    });
  });
}
