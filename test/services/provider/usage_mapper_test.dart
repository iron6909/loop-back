/// 三家用量响应映射测试
///
/// 形状与边界取自 `spike.md` 记录的实测响应与官方文档示例；断言值都是手算结果，
/// 不用实现再算一遍。
library;

import 'package:echo_loop/services/provider/usage_mapper.dart';
import 'package:echo_loop/services/provider/usage_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeepSeek 余额', () {
    test('字符串金额与构成字段全部保留', () {
      final snapshot = mapDeepSeekBalance({
        'is_available': true,
        'balance_infos': [
          {
            'currency': 'CNY',
            'total_balance': '110.00',
            'granted_balance': '10.00',
            'topped_up_balance': '100.00',
          },
        ],
      });

      expect(snapshot, isNotNull);
      expect(snapshot!.scope, UsageScope.account);
      final amount = snapshot.amounts.single;
      expect(amount.currency, 'CNY');
      expect(amount.total, 110.0);
      expect(amount.granted, 10.0);
      expect(amount.toppedUp, 100.0);
    });

    test('多币种各自保留，不混加', () {
      final snapshot = mapDeepSeekBalance({
        'balance_infos': [
          {'currency': 'USD', 'total_balance': '5.00'},
          {'currency': 'CNY', 'total_balance': '0'},
        ],
      });

      expect(snapshot!.amounts.length, 2);
      expect(snapshot.amounts.first.currency, 'USD');
      expect(snapshot.amounts.first.total, 5.0);
      expect(snapshot.amounts.last.total, 0.0);
      expect(snapshot.amounts.first.granted, isNull);
      expect(snapshot.amounts.first.toppedUp, isNull);
    });

    test('无法解析的金额被丢弃而不是置 0', () {
      final snapshot = mapDeepSeekBalance({
        'balance_infos': [
          {'currency': 'CNY', 'total_balance': 'n/a'},
        ],
      });

      expect(snapshot, isNull);
    });

    test('响应形状漂移返回空', () {
      expect(mapDeepSeekBalance({'balance_infos': 'oops'}), isNull);
    });

    test('非对象输入返回空', () {
      expect(mapDeepSeekBalance('not json'), isNull);
      expect(mapDeepSeekBalance(null), isNull);
    });
  });

  group('OpenRouter 账户余额', () {
    test('账户余额为总额减已用', () {
      final snapshot = mapOpenRouterCredits({
        'data': {'total_credits': 100.5, 'total_usage': 25.75},
      });

      expect(snapshot, isNotNull);
      expect(snapshot!.scope, UsageScope.account);
      expect(snapshot.amounts.single.currency, 'USD');
      expect(snapshot.amounts.single.total, 74.75);
    });

    test('缺 total_usage 时不出数', () {
      expect(
        mapOpenRouterCredits({
          'data': {'total_credits': 100.5},
        }),
        isNull,
      );
    });

    test('403 错误体不产出余额', () {
      expect(
        mapOpenRouterCredits({
          'error': {'code': 403, 'message': 'Only management keys'},
        }),
        isNull,
      );
    });
  });

  group('OpenRouter Key 预算', () {
    test('有预算时给出剩余额度与周期', () {
      final snapshot = mapOpenRouterKey({
        'data': {'limit_remaining': 74.5, 'limit_reset': 'monthly'},
      });

      expect(snapshot, isNotNull);
      expect(snapshot!.scope, UsageScope.keyBudget);
      expect(snapshot.amounts.single.total, 74.5);
      expect(snapshot.amounts.single.currency, 'USD');
      expect(snapshot.limitReset, 'monthly');
      expect(snapshot.budgetNotSet, isFalse);
    });

    test('未设预算时不显示 0，标记为未设预算', () {
      final snapshot = mapOpenRouterKey({
        'data': {'limit_remaining': null},
      });

      expect(snapshot, isNotNull);
      expect(snapshot!.budgetNotSet, isTrue);
      expect(snapshot.amounts, isEmpty);
      expect(snapshot.limitReset, isNull);
    });

    test('effective_budget 存在时单独标注', () {
      final snapshot = mapOpenRouterKey({
        'data': {
          'limit_remaining': 10,
          'effective_budget': {'monthly': 20},
        },
      });

      expect(snapshot!.hasEffectiveBudget, isTrue);
    });

    test('非对象输入返回空', () {
      expect(mapOpenRouterKey(<Object?>[]), isNull);
    });
  });

  group('OpenCode Go 套餐窗口', () {
    Map<String, Object?> threeWindows() => {
      'usage': {
        'rolling': {
          'status': 'ok',
          'percent': 37,
          'resetsAt': '2026-08-26T14:12:03.000Z',
        },
        'weekly': {
          'status': 'ok',
          'percent': 3,
          'resetsAt': '2026-08-17T00:00:00.287Z',
        },
        'monthly': {
          'status': 'rate-limited',
          'percent': 99,
          'resetsAt': '2026-09-13T06:06:01.287Z',
        },
      },
    };

    test('三窗口全部解析并保留顺序与重置时间', () {
      final snapshot = mapOpenCodeGoUsage(threeWindows());

      expect(snapshot, isNotNull);
      expect(snapshot!.scope, UsageScope.planWindow);
      expect(snapshot.windows.map((w) => w.kind), [
        UsageWindowKind.rolling,
        UsageWindowKind.weekly,
        UsageWindowKind.monthly,
      ]);
      expect(snapshot.windows.first.usedPercent, 37);
      expect(
        snapshot.windows.first.resetsAt,
        DateTime.parse('2026-08-26T14:12:03.000Z'),
      );
    });

    test('rate-limited 优先于百分比', () {
      final snapshot = mapOpenCodeGoUsage(threeWindows());

      expect(snapshot!.windows.last.rateLimited, isTrue);
      expect(snapshot.windows.last.usedPercent, 99);
      expect(snapshot.windows.first.rateLimited, isFalse);
    });

    test('percent=0 时丢弃占位重置时间', () {
      final snapshot = mapOpenCodeGoUsage({
        'usage': {
          'rolling': {
            'status': 'ok',
            'percent': 0,
            'resetsAt': '2026-10-31T18:00:00.000Z',
          },
        },
      });

      expect(snapshot!.windows.single.resetsAt, isNull);
      expect(snapshot.windows.single.usedPercent, 0);
    });

    test('已用最多的窗口即最紧张窗口', () {
      final snapshot = mapOpenCodeGoUsage(threeWindows());

      expect(snapshot!.tightestWindow?.kind, UsageWindowKind.monthly);
    });

    test('响应形状漂移返回空而不是崩溃', () {
      expect(
        mapOpenCodeGoUsage({
          'usage': {'rolling': 'unexpected'},
        }),
        isNull,
      );
    });

    test('非对象输入返回空', () {
      expect(mapOpenCodeGoUsage(null), isNull);
    });
  });
}
