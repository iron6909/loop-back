/// 学习计划页的阶段标题行（首次学习 / 各复习轮次共用）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// 学习计划阶段标题行标题列宽。
///
/// 首次学习与各复习轮次共用固定列宽，保证状态图标、状态文案和进度计数
/// 在不同行之间垂直对齐。
const double _stageHeaderTitleColumnWidth = 132;

/// 学习计划阶段标题行中文标题列宽。
const double _stageHeaderZhTitleColumnWidth = 112;

/// 学习计划阶段标题行状态文案列最大宽度。
const double _stageHeaderStatusTextMaxWidth = 180;

/// 学习计划阶段标题行进度计数列宽。
const double _stageHeaderProgressColumnWidth = 48;

/// 学习计划阶段标题行。
///
/// 固定关键列宽，避免某一行缺少状态文案时影响后续进度计数和展开箭头的列对齐。
class StudyStageHeaderRow extends StatelessWidget {
  final String keyPrefix;
  final Widget leadingIcon;
  final String title;
  final Color? titleColor;
  final Widget statusIcon;
  final String? statusText;
  final Color statusTextColor;
  final String progressText;
  final Color progressColor;
  final bool isExpanded;
  final VoidCallback onTap;

  const StudyStageHeaderRow({
    required this.keyPrefix,
    required this.leadingIcon,
    required this.title,
    this.titleColor,
    required this.statusIcon,
    this.statusText,
    required this.statusTextColor,
    required this.progressText,
    required this.progressColor,
    required this.isExpanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final titleColumnWidth = isZh
        ? _stageHeaderZhTitleColumnWidth
        : _stageHeaderTitleColumnWidth;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xs,
          vertical: AppSpacing.xs,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const horizontalGaps =
                AppSpacing.s +
                AppSpacing.xs +
                AppSpacing.s +
                AppSpacing.s +
                AppSpacing.xs;
            final fixedWidth =
                20 +
                titleColumnWidth +
                18 +
                _stageHeaderProgressColumnWidth +
                24 +
                horizontalGaps;
            final statusTextWidth = math
                .max(0, constraints.maxWidth - fixedWidth)
                .clamp(0, _stageHeaderStatusTextMaxWidth)
                .toDouble();

            return Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: Center(child: leadingIcon),
                ),
                const SizedBox(width: AppSpacing.s),
                SizedBox(
                  key: Key('${keyPrefix}_title_column'),
                  width: titleColumnWidth,
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: titleColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                SizedBox(
                  key: Key('${keyPrefix}_status_icon_column'),
                  width: 18,
                  height: 18,
                  child: Center(child: statusIcon),
                ),
                const SizedBox(width: AppSpacing.s),
                SizedBox(
                  key: Key('${keyPrefix}_status_text_column'),
                  width: statusTextWidth,
                  child: Text(
                    statusText ?? '',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: statusTextColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Spacer(),
                const SizedBox(width: AppSpacing.s),
                SizedBox(
                  key: Key('${keyPrefix}_progress_column'),
                  width: _stageHeaderProgressColumnWidth,
                  child: Text(
                    progressText,
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: progressColor,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                SizedBox(
                  key: Key('${keyPrefix}_expand_column'),
                  width: 24,
                  child: AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.expand_more,
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.4,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
