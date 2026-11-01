/// 用量卡：只读展示当前供应商的账户余额、Key 预算或套餐窗口（ui-spec S2）。
///
/// 九种状态由 [UsageView] 与 [isRefreshing] 组合决定；任何状态都不阻止 AI 请求，
/// 也不隐藏刷新入口。骨架用静态占位而非动画，避免无限动画让页面无法 settle。
library;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/provider/usage_models.dart';
import '../../../services/provider/usage_query_service.dart';
import '../../../theme/app_theme.dart';

/// 固定最小高度：状态切换时卡片不跳动。
const _minHeight = 132.0;

class UsageCard extends StatelessWidget {
  const UsageCard({
    super.key,
    required this.view,
    required this.providerName,
    required this.onRefresh,
    this.isRefreshing = false,
    this.onOpenConsole,
  });

  final UsageView view;
  final String providerName;
  final Future<void> Function() onRefresh;
  final bool isRefreshing;
  final VoidCallback? onOpenConsole;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Card(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _minHeight),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${providerName.isEmpty ? l10n.aiServiceTitle : providerName}'
                      '${_scopeSuffix(l10n)}',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.usageRefresh,
                    onPressed: isRefreshing ? null : () => onRefresh(),
                    icon: isRefreshing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Expanded(child: _body(context, l10n)),
              if (view.hasData) _footer(context, l10n),
            ],
          ),
        ),
      ),
    );
  }

  String _scopeSuffix(AppLocalizations l10n) => switch (view.snapshot?.scope) {
    UsageScope.account => ' · ${l10n.usageScopeAccount}',
    UsageScope.keyBudget => ' · ${l10n.usageScopeKeyBudget}',
    UsageScope.planWindow => ' · ${l10n.usageScopePlanWindow}',
    null => '',
  };

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    if (view.unsupported) {
      return _Notice(icon: Icons.info_outline, text: l10n.usageUnsupported);
    }
    if (!view.hasData) {
      if (view.failed) {
        // 从未成功：文案 + 重试（ui-spec S2 要求可直接重试）。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _Notice(icon: Icons.cloud_off_rounded, text: l10n.usageUnavailable),
            TextButton(
              onPressed: () => onRefresh(),
              child: Text(l10n.usageRetry),
            ),
          ],
        );
      }
      return _Skeleton(theme: theme);
    }
    final snapshot = view.snapshot;
    if (snapshot == null) return _Skeleton(theme: theme);
    return switch (snapshot.scope) {
      UsageScope.planWindow => _windows(context, l10n, snapshot),
      UsageScope.account || UsageScope.keyBudget =>
        _amounts(context, l10n, snapshot),
    };
  }

  /// 套餐窗口：剩余最少的有效窗口置顶并加粗。
  Widget _windows(
    BuildContext context,
    AppLocalizations l10n,
    UsageSnapshot snapshot,
  ) {
    final theme = Theme.of(context);
    final tightest = snapshot.tightestWindow;
    final ordered = [
      if (tightest != null) tightest,
      ...snapshot.windows.where((w) => w != tightest),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final window in ordered)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    _windowName(l10n, window.kind),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  child: LinearProgressIndicator(
                    value: (window.usedPercent / 100).clamp(0, 1),
                  ),
                ),
                const SizedBox(width: AppSpacing.s),
                Text(
                  '${window.usedPercent.round()}%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: window == tightest ? FontWeight.w700 : null,
                  ),
                ),
                if (window.rateLimited) ...[
                  const SizedBox(width: AppSpacing.xs),
                  Icon(Icons.warning_amber_rounded,
                      size: 16, color: theme.colorScheme.error),
                  Text(l10n.usageRateLimited, style: theme.textTheme.bodySmall),
                ] else if (window.resetsAt case final resetsAt?) ...[
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    l10n.usageResetsAt(_clock(resetsAt)),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  String _windowName(AppLocalizations l10n, UsageWindowKind kind) =>
      switch (kind) {
        UsageWindowKind.rolling => l10n.usageWindowRolling,
        UsageWindowKind.weekly => l10n.usageWindowWeekly,
        UsageWindowKind.monthly => l10n.usageWindowMonthly,
      };

  /// 金额：多币种各一行，不合并；无预算时明确说明而不是显示 0。
  Widget _amounts(
    BuildContext context,
    AppLocalizations l10n,
    UsageSnapshot snapshot,
  ) {
    final theme = Theme.of(context);
    final reset = snapshot.limitReset;
    if (snapshot.scope == UsageScope.keyBudget && snapshot.budgetNotSet) {
      return _Notice(icon: Icons.savings_outlined, text: l10n.usageBudgetNotSet);
    }
    if (snapshot.amounts.isEmpty) {
      return _Notice(icon: Icons.info_outline, text: l10n.usageUnavailable);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final amount in snapshot.amounts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _money(amount),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (amount.granted case final granted?)
                  Text(
                    '${l10n.usageGranted(_plain(granted, amount.currency))}'
                    '${amount.toppedUp == null ? '' : ' \u00b7 ${l10n.usageToppedUp(_plain(amount.toppedUp!, amount.currency))}'}',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        if (snapshot.scope == UsageScope.keyBudget && reset != null)
          Text(reset, style: theme.textTheme.bodySmall),
        if (snapshot.hasEffectiveBudget)
          Text(l10n.usageEffectiveBudget, style: theme.textTheme.bodySmall),
      ],
    );
  }

  /// 主值：币种符号 + 保留两位 + 币种代码（多币种不混加）。
  String _money(UsageAmount amount) =>
      '${_symbol(amount.currency)}${amount.total.toStringAsFixed(2)} '
      '${amount.currency}';

  String _plain(double value, String currency) =>
      '${_symbol(currency)}${value.toStringAsFixed(2)}';

  String _symbol(String currency) => switch (currency) {
    'CNY' => '\u00a5',
    'USD' => r'$',
    _ => '',
  };

  Widget _footer(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final fetchedAt = view.fetchedAt;
    final text = view.failed
        ? (fetchedAt == null
              ? l10n.usageUnavailable
              : l10n.usageUpdateFailed(_clock(fetchedAt)))
        : (fetchedAt == null ? '' : l10n.usageUpdatedAt(_clock(fetchedAt)));
    if (text.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        if (view.failed)
          Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
        if (view.failed) const SizedBox(width: AppSpacing.xs),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        if (view.failed)
          TextButton(onPressed: () => onRefresh(), child: Text(l10n.usageRetry)),
      ],
    );
  }

  String _clock(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}

/// 静态骨架：保留高度，不显示任何数字。
class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final width in [140.0, 96.0])
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.s),
          child: Container(
            width: width,
            height: 14,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12), // DESIGN.md radiusInput
            ),
          ),
        ),
    ],
  );
}

/// 无数据类状态：图标 + 文字双通道。
class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
      const SizedBox(width: AppSpacing.s),
      Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
    ],
  );
}
