import 'package:loop_back/models/retell_review_evaluation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('完整 schema 解析出全部字段', () {
    final result = RetellReviewEvaluation.fromJson(<String, dynamic>{
      'summary': '你准确传达了主要观点。',
      'keyPoints': [
        {
          'keyPoint': '练习提升流利度',
          'original': 'Practice makes you fluent.',
          'transcript': 'practice makes you speak better',
          'status': 'covered',
          'feedback': null,
        },
        {
          'keyPoint': '反馈很重要',
          'original': 'Feedback matters.',
          'transcript': 'feedback is good',
          'status': 'partial',
          'feedback': '只说了一半。',
        },
        {
          'keyPoint': '睡眠巩固记忆',
          'original': 'Sleep consolidates memory.',
          'transcript': null,
          'status': 'missed',
          'feedback': '完全没有提到。',
        },
        {
          'keyPoint': '因果关系',
          'original': 'Practice makes you fluent.',
          'transcript': 'because you are fluent you practice',
          'status': 'distorted',
          'feedback': '把因果说反了。',
        },
        {
          'keyPoint': '每天要练两小时',
          'original': null,
          'transcript': 'you must practice two hours a day',
          'status': 'added',
          'feedback': '原文没有提到任何练习时长。',
        },
      ],
      'suggestion': '复述前先列三个关键词。',
      'corrections': [
        {
          'type': 'grammar',
          'transcript': 'he don\'t know',
          'correction': 'he doesn\'t know',
          'explanation': '第三人称单数用 doesn\'t。',
        },
      ],
      'rating': 'excellent',
    });

    expect(result.summary, '你准确传达了主要观点。');
    expect(result.rating, RetellReviewRating.excellent);
    expect(result.suggestion, '复述前先列三个关键词。');
    expect(
      result.keyPoints.map((e) => e.status).toList(),
      RetellReviewKeyPointStatus.values,
    );
    // 服务端 covered 时 feedback 为 null，模型统一收敛成空串。
    expect(result.keyPoints.first.feedback, '');
    expect(result.keyPoints[1].feedback, '只说了一半。');
    // 摘录是该条判定的证据；missed 没有对应摘录，服务端返回 null，收敛成空串。
    expect(
      result.keyPoints.first.transcript,
      'practice makes you speak better',
    );
    expect(result.keyPoints[2].transcript, '');
    expect(result.keyPoints.last.status, RetellReviewKeyPointStatus.added);
    expect(
      result.keyPoints.last.transcript,
      'you must practice two hours a day',
    );
    expect(result.corrections.single.type, RetellReviewCorrectionType.grammar);
    expect(result.corrections.single.transcript, 'he don\'t know');
    expect(result.corrections.single.correction, 'he doesn\'t know');
    expect(result.corrections.single.explanation, '第三人称单数用 doesn\'t。');
    // keyPoint 是母语要点陈述，原文摘录单独放 original，两者不混用。
    expect(result.keyPoints.first.keyPoint, '练习提升流利度');
    expect(result.keyPoints.first.original, 'Practice makes you fluent.');
    // added 的要点原文里没有，服务端 original 返回 null，收敛成空串。
    expect(result.keyPoints.last.keyPoint, '每天要练两小时');
    expect(result.keyPoints.last.original, '');
  });

  test('五个纠错类别 token 全部正确映射', () {
    final result = RetellReviewEvaluation.fromJson(<String, dynamic>{
      'corrections': [
        for (final type in [
          'grammar',
          'wordChoice',
          'redundancy',
          'phrasing',
          'cohesion',
        ])
          {
            'type': type,
            'transcript': 'x',
            'correction': 'y',
            'explanation': 'z',
          },
      ],
    });

    expect(
      result.corrections.map((e) => e.type).toList(),
      RetellReviewCorrectionType.values,
    );
  });

  test('纠错类别缺失或无法识别时为 null，条目本身仍保留', () {
    final result = RetellReviewEvaluation.fromJson(<String, dynamic>{
      'corrections': [
        {'transcript': 'he don\'t know', 'correction': 'he doesn\'t know'},
        {'type': 'pronunciation', 'transcript': 'x', 'correction': 'y'},
      ],
    });

    expect(result.corrections, hasLength(2));
    expect(result.corrections.first.type, isNull);
    expect(result.corrections.first.explanation, '');
    expect(result.corrections[1].type, isNull);
  });

  test('最低评级 token poor 正确映射', () {
    final result = RetellReviewEvaluation.fromJson(<String, dynamic>{
      'rating': 'poor',
    });

    expect(result.rating, RetellReviewRating.poor);
  });

  test('评级缺失或无法识别时为 null，不兜底成最差评级', () {
    expect(RetellReviewEvaluation.fromJson(const {}).rating, isNull);
    expect(
      RetellReviewEvaluation.fromJson(<String, dynamic>{
        'rating': 'unexpected',
      }).rating,
      isNull,
    );
  });

  test('流式半成品：要点文本先到、状态未到时 status 为 null', () {
    final result = RetellReviewEvaluation.fromJson(<String, dynamic>{
      'summary': '表达了核心意思。',
      'keyPoints': [
        {'keyPoint': '练习提升流利度'},
        null,
      ],
      'corrections': 'not-a-list',
    });

    expect(result.summary, '表达了核心意思。');
    expect(result.rating, isNull);
    expect(result.keyPoints, hasLength(1));
    expect(result.keyPoints.single.keyPoint, '练习提升流利度');
    expect(result.keyPoints.single.original, '');
    expect(result.keyPoints.single.transcript, '');
    expect(result.keyPoints.single.status, isNull);
    expect(result.keyPoints.single.feedback, '');
    expect(result.suggestion, '');
    expect(result.corrections, isEmpty);
  });

  test('转录先到、AI 字段全空时也是合法快照', () {
    final result = RetellReviewEvaluation.fromJson(<String, dynamic>{
      'transcript': 'I practiced today.',
    });

    expect(result.transcript, 'I practiced today.');
    expect(result.summary, '');
    expect(result.rating, isNull);
    expect(result.keyPoints, isEmpty);
    expect(result.suggestion, '');
    expect(result.corrections, isEmpty);
  });
}
