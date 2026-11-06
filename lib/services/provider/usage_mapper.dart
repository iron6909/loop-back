/// 三家供应商用量响应的纯映射
///
/// 只做「响应 → 领域模型」，不发请求、不缓存、不看时间（缓存与并发合并属
/// `UsageQueryService`）。形状不认识时返回 null 而不是抛错：用量是只读附加信息，
/// 任何形状漂移都不该影响推理。
library;

import 'usage_models.dart';

/// 映射 DeepSeek `GET /user/balance`。
///
/// 金额是字符串且可能多币种：逐条解析，解析不了的那条直接丢弃（不置 0），
/// 一条都解析不出来就返回 null。`is_available` 只作状态，不参与金额计算。
UsageSnapshot? mapDeepSeekBalance(Object? body) {
  if (body is! Map<String, dynamic>) return null;
  final rows = body['balance_infos'];
  if (rows is! List) return null;

  final amounts = <UsageAmount>[];
  for (final row in rows) {
    if (row is! Map<String, dynamic>) continue;
    final total = _number(row['total_balance']);
    final currency = row['currency'];
    if (total == null || currency is! String || currency.isEmpty) continue;
    amounts.add(
      UsageAmount(
        currency: currency.toUpperCase(),
        total: total,
        granted: _number(row['granted_balance']),
        toppedUp: _number(row['topped_up_balance']),
      ),
    );
  }
  if (amounts.isEmpty) return null;
  return UsageSnapshot(scope: UsageScope.account, amounts: amounts);
}

/// 映射 OpenRouter `GET /api/v1/credits`（账户级）。
///
/// 余额 = `total_credits - total_usage`；任一项缺失就不出数。403 等错误体没有
/// `data`，自然返回 null，由调用方按状态码区分「无权限」与「Key 无效」。
UsageSnapshot? mapOpenRouterCredits(Object? body) {
  if (body is! Map<String, dynamic>) return null;
  final data = body['data'];
  if (data is! Map<String, dynamic>) return null;

  final total = _number(data['total_credits']);
  final used = _number(data['total_usage']);
  if (total == null || used == null) return null;

  return UsageSnapshot(
    scope: UsageScope.account,
    amounts: [UsageAmount(currency: 'USD', total: total - used)],
  );
}

/// 映射 OpenRouter `GET /api/v1/key`（Key 级预算）。
///
/// `limit_remaining` 为 null 表示未设预算：标记 [UsageSnapshot.budgetNotSet]，
/// 不产出金额，避免显示成 0。
UsageSnapshot? mapOpenRouterKey(Object? body) {
  if (body is! Map<String, dynamic>) return null;
  final data = body['data'];
  if (data is! Map<String, dynamic>) return null;

  final remaining = _number(data['limit_remaining']);
  final reset = data['limit_reset'];
  return UsageSnapshot(
    scope: UsageScope.keyBudget,
    amounts: remaining == null
        ? const []
        : [UsageAmount(currency: 'USD', total: remaining)],
    budgetNotSet: remaining == null,
    hasEffectiveBudget: data['effective_budget'] != null,
    limitReset: reset is String && reset.isNotEmpty ? reset : null,
  );
}

/// 映射 OpenCode Go `GET /zen/go/v1/usage` 的三窗口。
///
/// 两条实测规则：`percent` 为 0 时 `resetsAt` 是占位值，必须丢弃；
/// `status=rate-limited` 优先于百分比（百分比可能被向下取整到 99）。
UsageSnapshot? mapOpenCodeGoUsage(Object? body) {
  if (body is! Map<String, dynamic>) return null;
  final usage = body['usage'];
  if (usage is! Map<String, dynamic>) return null;

  const kinds = [
    (UsageWindowKind.rolling, 'rolling'),
    (UsageWindowKind.weekly, 'weekly'),
    (UsageWindowKind.monthly, 'monthly'),
  ];

  final windows = <UsageWindow>[];
  for (final (kind, key) in kinds) {
    final raw = usage[key];
    if (raw is! Map<String, dynamic>) continue;
    final percent = _number(raw['percent']);
    if (percent == null) continue;

    DateTime? resetsAt;
    final resetRaw = raw['resetsAt'];
    if (percent > 0 && resetRaw is String) {
      resetsAt = DateTime.tryParse(resetRaw);
    }

    windows.add(
      UsageWindow(
        kind: kind,
        usedPercent: percent,
        rateLimited: raw['status'] == 'rate-limited',
        resetsAt: resetsAt,
      ),
    );
  }
  if (windows.isEmpty) return null;
  return UsageSnapshot(scope: UsageScope.planWindow, windows: windows);
}

/// 宽容读取数字：接受 `num` 与数字字符串，其余（含 `'n/a'`）返回 null。
double? _number(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}
