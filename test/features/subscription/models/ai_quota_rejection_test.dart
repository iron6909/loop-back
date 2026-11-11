import 'package:loop_back/features/subscription/models/ai_quota_rejection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('402 quota_exceeded 的数值型 limit=0 表示免费版不支持', () {
    final rejection = AiQuotaRejection.fromResponseData({
      'code': 'quota_exceeded',
      'quota': {'used': 0, 'limit': 0},
    });

    expect(rejection.reason, AiQuotaRejectionReason.unsupportedForFreePlan);
  });

  test('正数、缺失、字符串 limit 与其它 code 均保持额度用尽语义', () {
    final payloads = <Object?>[
      {
        'code': 'quota_exceeded',
        'quota': {'limit': 3},
      },
      {'code': 'quota_exceeded', 'quota': <String, Object?>{}},
      {
        'code': 'quota_exceeded',
        'quota': {'limit': '0'},
      },
      {
        'code': 'other_error',
        'quota': {'limit': 0},
      },
      null,
    ];

    for (final payload in payloads) {
      expect(
        AiQuotaRejection.fromResponseData(payload).reason,
        AiQuotaRejectionReason.exhausted,
      );
    }
  });

  test('resetAt 解析为 UTC，非法值忽略', () {
    final rejection = AiQuotaRejection.fromResponseData({
      'code': 'quota_exceeded',
      'quota': {'resetAt': '2026-08-01T08:00:00+08:00'},
    });

    expect(rejection.resetAt, DateTime.utc(2026, 8));
    expect(
      AiQuotaRejection.fromResponseData({
        'code': 'quota_exceeded',
        'quota': {'resetAt': 'invalid'},
      }).resetAt,
      isNull,
    );
  });
}
