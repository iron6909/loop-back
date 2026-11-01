/// 供应商用量的领域模型
///
/// 只保留展示所需的最小字段，不保存原始账户响应（spec「用量数据形状」）。金额一律
/// 用 `double` 承载，无法解析的值保持 null / 被丢弃，**绝不置 0**——0 是一个有意义
/// 的真实余额，猜成 0 会让用户以为额度耗尽。
library;

/// 用量数据的范围标注。UI 必须显式展示，避免把 Key 预算误读成账户余额。
enum UsageScope {
  /// 账户级余额（DeepSeek `/user/balance`、OpenRouter `/credits`）。
  account,

  /// Key 级预算余额（OpenRouter `/key`）。
  keyBudget,

  /// 套餐窗口（OpenCode Go 三窗口）。
  planWindow,
}

/// 套餐窗口种类。
///
/// 只给稳定的枚举值，展示文案由 UI 按界面语言本地化，不把中文写进数据层。
enum UsageWindowKind {
  /// 5 小时滚动窗口。
  rolling,

  /// 每周窗口。
  weekly,

  /// 每月窗口。
  monthly,
}

/// 一条金额余额。[currency] 保留原始币种，多币种不混加。
class UsageAmount {
  const UsageAmount({
    required this.currency,
    required this.total,
    this.granted,
    this.toppedUp,
  });

  /// 币种代码（如 `CNY` / `USD`），已统一大写。
  final String currency;

  /// 可用总额。
  final double total;

  /// 赠送额度；响应未给出时为 null。
  final double? granted;

  /// 充值额度；响应未给出时为 null。
  final double? toppedUp;
}

/// 一个套餐窗口。
class UsageWindow {
  const UsageWindow({
    required this.kind,
    required this.usedPercent,
    required this.rateLimited,
    this.resetsAt,
  });

  /// 窗口种类。
  final UsageWindowKind kind;

  /// 已用百分比（0–100）。
  final double usedPercent;

  /// 服务端是否已标记限流。优先级高于 [usedPercent]。
  final bool rateLimited;

  /// 重置时间；`percent` 为 0 时不采信服务端的占位值，保持 null。
  final DateTime? resetsAt;
}

/// 一次用量查询的映射结果。
class UsageSnapshot {
  const UsageSnapshot({
    required this.scope,
    this.amounts = const [],
    this.windows = const [],
    this.budgetNotSet = false,
    this.hasEffectiveBudget = false,
    this.limitReset,
  });

  /// 数据范围。
  final UsageScope scope;

  /// 金额类数据（账户余额或 Key 预算）。
  final List<UsageAmount> amounts;

  /// 窗口类数据（套餐窗口）。
  final List<UsageWindow> windows;

  /// Key 未设预算。UI 应显示「未设预算」，不能显示 0。
  final bool budgetNotSet;

  /// 响应带 `effective_budget`，需单独标注。
  final bool hasEffectiveBudget;

  /// 预算周期（如 `monthly`）；未给出时为 null。
  final String? limitReset;

  /// 已用比例最高的窗口，即剩余最少的窗口；无窗口时为 null。
  UsageWindow? get tightestWindow {
    if (windows.isEmpty) return null;
    var tightest = windows.first;
    for (final window in windows.skip(1)) {
      if (window.usedPercent > tightest.usedPercent) tightest = window;
    }
    return tightest;
  }
}
