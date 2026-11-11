/// 结构化结果严格校验器测试
///
/// 覆盖 spec「结果校验」表：六项功能各含通过样例与失败样例；并锁定 spike 实测
/// 的两处已知脆弱点——意群大小写变化被拒、`medium` 为字符串时不得依赖 `fromJson`
/// 容错（它会对非数组抛 `TypeError`）。
library;

import 'package:loop_back/models/dictionary/dictionary_entry.dart';
import 'package:loop_back/models/retell_review_evaluation.dart';
import 'package:loop_back/models/sense_group_result.dart';
import 'package:loop_back/models/sentence_ai_result.dart';
import 'package:loop_back/services/provider/structured_result_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('翻译', () {
    test('translation 非空时通过并携带领域对象', () {
      final outcome = validateTranslation({'translation': '这是一个测试。'});

      expect(outcome, isA<ValidationSuccess<SentenceTranslation>>());
      expect(
        (outcome as ValidationSuccess<SentenceTranslation>).value.translation,
        '这是一个测试。',
      );
    });

    test('translation 为空串判失败', () {
      expect(
        _reason(validateTranslation({'translation': '   '})),
        ValidationFailureReason.missingField,
      );
    });

    test('translation 非字符串判字段类型失败', () {
      expect(
        _reason(validateTranslation({'translation': 42})),
        ValidationFailureReason.fieldType,
      );
    });
  });

  group('句子解析', () {
    Map<String, dynamic> validAnalysis() => {
      'grammar': [
        {'point': '现在完成时', 'note': '表示过去动作对现在的影响'},
      ],
      'vocabulary': [
        {'term': 'commute', 'note': '通勤'},
      ],
      'listening': [
        {'phrase': 'wanna', 'note': 'want to 的弱读连读'},
      ],
    };

    test('grammar 与 listening 非空时通过', () {
      final outcome = validateAnalysis(validAnalysis());

      expect(outcome, isA<ValidationSuccess<SentenceAnalysis>>());
      final value = (outcome as ValidationSuccess<SentenceAnalysis>).value;
      expect(value.grammar.single.point, '现在完成时');
      expect(value.listening.single.phrase, 'wanna');
    });

    test('grammar 为空列表判失败', () {
      final json = validAnalysis()..['grammar'] = <Object?>[];
      expect(
        _reason(validateAnalysis(json)),
        ValidationFailureReason.missingField,
      );
    });

    test('listening 缺 note 判失败', () {
      final json = validAnalysis()
        ..['listening'] = [
          {'phrase': 'wanna'},
        ];
      expect(
        _reason(validateAnalysis(json)),
        ValidationFailureReason.missingField,
      );
    });

    test('vocabulary 项 term 为空判失败', () {
      final json = validAnalysis()
        ..['vocabulary'] = [
          {'term': '  ', 'note': '通勤'},
        ];
      expect(
        _reason(validateAnalysis(json)),
        ValidationFailureReason.missingField,
      );
    });

    test('grammar 非数组判字段类型失败', () {
      final json = validAnalysis()..['grammar'] = '现在完成时';
      expect(
        _reason(validateAnalysis(json)),
        ValidationFailureReason.fieldType,
      );
    });
  });

  group('单词', () {
    Map<String, dynamic> validWord() => {
      'headword': 'commute',
      'meanings': [
        {
          'partOfSpeech': 'v.',
          'definition': 'to travel regularly between home and work',
          'translation': ['通勤'],
        },
      ],
    };

    test('headword 与 meanings 齐备时通过', () {
      final outcome = validateWordEntry(validWord());

      expect(outcome, isA<ValidationSuccess<DictionaryEntry>>());
      expect(
        (outcome as ValidationSuccess<DictionaryEntry>).value.headword,
        'commute',
      );
    });

    test('meanings 为空列表判失败', () {
      final json = validWord()..['meanings'] = <Object?>[];
      expect(
        _reason(validateWordEntry(json)),
        ValidationFailureReason.missingField,
      );
    });

    test('义项 translation 为空判失败', () {
      final json = validWord()
        ..['meanings'] = [
          {
            'partOfSpeech': 'v.',
            'definition': 'to travel regularly',
            'translation': <Object?>[],
          },
        ];
      expect(
        _reason(validateWordEntry(json)),
        ValidationFailureReason.missingField,
      );
    });

    test('headword 缺失判失败', () {
      final json = validWord()..remove('headword');
      expect(
        _reason(validateWordEntry(json)),
        ValidationFailureReason.missingField,
      );
    });
  });

  group('短语', () {
    Map<String, dynamic> validPhrase() => {
      'originalExpression': 'give up on',
      'category': '短语动词',
      'keyPoints': [
        {'point': '表示放弃对某人或某事的期望'},
      ],
      'meanings': [
        {
          'translation': ['对……不再抱希望'],
        },
      ],
    };

    test('originalExpression、category、keyPoints 齐备时通过', () {
      final outcome = validatePhraseEntry(validPhrase());

      expect(outcome, isA<ValidationSuccess<MultiWordDictionaryEntry>>());
      expect(
        (outcome as ValidationSuccess<MultiWordDictionaryEntry>)
            .value
            .originalExpression,
        'give up on',
      );
    });

    test('category 为空判失败', () {
      final json = validPhrase()..['category'] = '';
      expect(
        _reason(validatePhraseEntry(json)),
        ValidationFailureReason.missingField,
      );
    });

    test('keyPoints 为空列表判失败', () {
      final json = validPhrase()..['keyPoints'] = <Object?>[];
      expect(
        _reason(validatePhraseEntry(json)),
        ValidationFailureReason.missingField,
      );
    });

    test('义项 translation 为空判失败', () {
      final json = validPhrase()
        ..['meanings'] = [
          {'translation': <Object?>[]},
        ];
      expect(
        _reason(validatePhraseEntry(json)),
        ValidationFailureReason.missingField,
      );
    });
  });

  group('意群', () {
    const original = 'I want to go home now.';
    Map<String, dynamic> validChunks() => {
      'medium': ['I want', ' to go', ' home', ' now.'],
      'fine': ['I', ' want', ' to go', ' home', ' now.'],
    };

    test('两种粒度均与原文守恒时通过', () {
      final outcome = validateSenseGroups(validChunks(), original: original);

      expect(outcome, isA<ValidationSuccess<SenseGroupResult>>());
      expect(
        (outcome as ValidationSuccess<SenseGroupResult>).value.medium,
        ['I want', ' to go', ' home', ' now.'],
      );
    });

    test('仅大小写不同即判不守恒（spike 实测零容忍）', () {
      final json = validChunks()..['medium'] = ['i want', ' to go', ' home', ' now.'];
      expect(
        _reason(validateSenseGroups(json, original: original)),
        ValidationFailureReason.notConserved,
      );
    });

    test('medium 为字符串时判字段类型失败，不依赖 fromJson 抛错', () {
      final json = validChunks()..['medium'] = 'I want to go home now.';
      expect(
        _reason(validateSenseGroups(json, original: original)),
        ValidationFailureReason.fieldType,
      );
    });

    test('medium 为空列表判失败', () {
      final json = validChunks()..['medium'] = <Object?>[];
      expect(
        _reason(validateSenseGroups(json, original: original)),
        ValidationFailureReason.missingField,
      );
    });

    test('fine 不守恒同样判失败', () {
      final json = validChunks()..['fine'] = ['I', ' want', ' to go', ' home'];
      expect(
        _reason(validateSenseGroups(json, original: original)),
        ValidationFailureReason.notConserved,
      );
    });
  });

  group('复述评估', () {
    Map<String, dynamic> validRetell() => {
      'rating': 'good',
      'summary': '整体表达清楚，缺少一个要点。',
      'keyPoints': [
        {
          'keyPoint': '提到通勤时间变长',
          'status': 'covered',
        },
      ],
      'corrections': [
        {
          'type': 'wordChoice',
          'transcript': 'I go to work by bus',
          'correction': 'I commute by bus',
        },
      ],
    };

    test('rating、summary、keyPoints 齐备时通过', () {
      final outcome = validateRetell(validRetell());

      expect(outcome, isA<ValidationSuccess<RetellReviewEvaluation>>());
      final value = (outcome as ValidationSuccess<RetellReviewEvaluation>).value;
      expect(value.rating, RetellReviewRating.good);
      expect(value.keyPoints.single.status, RetellReviewKeyPointStatus.covered);
    });

    test('rating 不在枚举内判失败', () {
      final json = validRetell()..['rating'] = 'great';
      expect(
        _reason(validateRetell(json)),
        ValidationFailureReason.invalidEnum,
      );
    });

    test('rating 缺失判失败', () {
      final json = validRetell()..remove('rating');
      expect(
        _reason(validateRetell(json)),
        ValidationFailureReason.invalidEnum,
      );
    });

    test('要点 status 不在枚举内判失败', () {
      final json = validRetell()
        ..['keyPoints'] = [
          {'keyPoint': '提到通勤时间变长', 'status': 'unknown'},
        ];
      expect(
        _reason(validateRetell(json)),
        ValidationFailureReason.invalidEnum,
      );
    });

    test('summary 为空判失败', () {
      final json = validRetell()..['summary'] = '';
      expect(
        _reason(validateRetell(json)),
        ValidationFailureReason.missingField,
      );
    });

    test('keyPoints 为空列表判失败', () {
      final json = validRetell()..['keyPoints'] = <Object?>[];
      expect(
        _reason(validateRetell(json)),
        ValidationFailureReason.missingField,
      );
    });

    test('纠错项 transcript 为空判失败', () {
      final json = validRetell()
        ..['corrections'] = [
          {
            'type': 'grammar',
            'transcript': '',
            'correction': 'I commute by bus',
          },
        ];
      expect(
        _reason(validateRetell(json)),
        ValidationFailureReason.missingField,
      );
    });
  });

  group('通用输入形态', () {
    test('null 输入判空正文', () {
      expect(
        _reason(validateTranslation(null)),
        ValidationFailureReason.emptyBody,
      );
    });

    test('空字符串输入判空正文', () {
      expect(
        _reason(validateTranslation('')),
        ValidationFailureReason.emptyBody,
      );
    });

    test('顶层非对象判非 JSON 对象', () {
      expect(
        _reason(validateTranslation(<Object?>['translation'])),
        ValidationFailureReason.notJsonObject,
      );
    });
  });
}

/// 取出失败原因；通过时返回 null，让断言直接看到意外成功。
ValidationFailureReason? _reason<T>(ValidationOutcome<T> outcome) {
  return switch (outcome) {
    ValidationFailure<T>(:final reason) => reason,
    ValidationSuccess<T>() => null,
  };
}
