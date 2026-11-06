import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/collection.dart';
import '../../../theme/app_theme.dart';

/// 历史社区合集已停止同步的灰色角标。
class CommunitySyncStoppedBadge extends StatelessWidget {
  const CommunitySyncStoppedBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = AppLocalizations.of(context)!.communitySyncStoppedBadge;
    return Semantics(
      label: label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: theme.colorScheme.outline,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            height: 1.2,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

/// 合集来源角标：贴在合集封面角上的文字小标签。
///
/// 设计目标：用最小占位直接传达语义，无需用户解读图标。
/// - 本地：深蓝圆角胶囊 + 白色"本地"文字
/// - 社区：绿色圆角胶囊 + 白色"共享"文字
/// - 播客：深紫圆角胶囊 + 白色"播客"文字
/// - 已下架：灰色圆角胶囊 + 白色"已下架"文字
///
/// 同时保留 Semantics + Tooltip 以兼容无障碍读屏。
class CollectionSourceCornerBadge extends StatelessWidget {
  /// 合集来源。
  final CollectionSource source;

  /// 是否处于已下架状态。
  final bool isDeprecated;

  const CollectionSourceCornerBadge({
    super.key,
    required this.source,
    this.isDeprecated = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final label = _label(l10n);
    final bgColor = _backgroundColor(theme);
    return Semantics(
      label: label,
      child: Tooltip(
        message: label,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(6),
            // 不加描边：深色背景 + 白字本身已有强对比；白边在小尺寸上反而显朦胧
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 2,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              height: 1.2,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }

  String _label(AppLocalizations l10n) {
    if (source == CollectionSource.community && isDeprecated) {
      return l10n.communityDeprecatedBadge;
    }
    return switch (source) {
      CollectionSource.local => l10n.localCollectionBadge,
      CollectionSource.community => l10n.communityBadge,
      CollectionSource.podcast => l10n.podcastCollectionBadge,
    };
  }

  Color _backgroundColor(ThemeData theme) {
    if (source == CollectionSource.community && isDeprecated) {
      return theme.colorScheme.outline;
    }
    return switch (source) {
      CollectionSource.local => AppTheme.localCollectionBadgeColor,
      CollectionSource.community => AppTheme.communityBadgeColor,
      CollectionSource.podcast => AppTheme.podcastCollectionBadgeColor,
    };
  }
}
