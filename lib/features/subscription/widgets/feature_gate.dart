/// 付费墙门控组件。
///
/// 纯展示：watch [featureAccessProvider]，解锁渲染 [child]，锁定渲染 [locked] 占位。
/// 订阅、登录与后端配额已停用，因此不再提供跳转升级页的入口。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../models/premium_feature.dart';
import '../providers/feature_access_provider.dart';

/// 提示订阅能力已停用（历史上这里是「撞墙后跳 Paywall」的唯一入口）。
Future<void> openPaywall(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(l10n.premiumUnavailableOnPlatform)),
  );
}

/// 根据 [feature] 是否解锁，在 [child] 与锁定占位间切换的门控组件。
class FeatureGate extends ConsumerWidget {
  const FeatureGate({
    super.key,
    required this.feature,
    required this.child,
    this.locked,
    this.onLockedTap,
  });

  /// 受保护的能力。
  final PremiumFeature feature;

  /// 解锁时渲染的内容。
  final Widget child;

  /// 锁定时渲染的占位（为 null 时锁定渲染空白 [SizedBox.shrink]）。
  final Widget? locked;

  /// 锁定占位被点击时的回调（为 null 时默认跳 Paywall）。
  final VoidCallback? onLockedTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlocked = ref.watch(featureAccessProvider(feature));
    if (unlocked) return child;
    final placeholder = locked;
    if (placeholder == null) return const SizedBox.shrink();
    return InkWell(
      onTap: () => (onLockedTap ?? () => openPaywall(context, ref))(),
      child: placeholder,
    );
  }
}
