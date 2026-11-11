/// 调试假数据的覆盖度测试。
///
/// 假数据的价值就在于「一次看全各种情况」，所以这里守住覆盖面：枚举新增成员时
/// 测试立刻失败，提醒把新情况补进假数据，而不是等到界面上漏了才发现。
library;

import 'package:loop_back/models/retell_review_evaluation.dart';
import 'package:loop_back/models/retell_review_sample.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sample = retellReviewSampleEvaluation();

  test('五种要点状态全部出现，且含一条状态未到达的流式半成品', () {
    final statuses = sample.keyPoints.map((e) => e.status).toSet();
    for (final status in RetellReviewKeyPointStatus.values) {
      expect(statuses, contains(status), reason: '假数据缺少状态 $status');
    }
    expect(statuses, contains(null), reason: '假数据缺少「状态尚未到达」的条目');
  });

  test('五种纠错类别全部出现', () {
    final types = sample.corrections.map((e) => e.type).toSet();
    for (final type in RetellReviewCorrectionType.values) {
      expect(types, contains(type), reason: '假数据缺少纠错类别 $type');
    }
  });

  test('要点的缺失分支都有样本：无原文摘录、无转录摘录、无反馈', () {
    expect(
      sample.keyPoints.where((e) => e.original.isEmpty),
      isNotEmpty,
      reason: 'added 条目应演示「原文行整行不出现」',
    );
    expect(
      sample.keyPoints.where((e) => e.transcript.isEmpty),
      isNotEmpty,
      reason: 'missed 条目应演示「我说」行的占位文案',
    );
    expect(
      sample.keyPoints.where((e) => e.feedback.isEmpty),
      isNotEmpty,
      reason: '应有条目演示「提示」行不出现',
    );
  });

  test('顶层字段齐全，报告不会有空区块', () {
    expect(sample.transcript, isNotEmpty);
    expect(sample.summary, isNotEmpty);
    expect(sample.suggestion, isNotEmpty);
    expect(sample.rating, isNotNull);
  });

  test('开关默认关闭，避免调试用的假数据被误提交进正常链路', () {
    expect(retellReviewSampleEnabled, isFalse);
  });
}
