/// 学习计划页 AppBar 的「随心听」入口按钮。
library;

import 'package:flutter/material.dart';

/// 学习计划页 AppBar 的「自由练习」入口。
///
/// 这里不用普通文字按钮，而是做成轻量 CTA 胶囊，提升可发现性，
/// 同时控制横向占用，避免在移动端把标题进一步挤压。
class FreePlayAppBarButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const FreePlayAppBarButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final surfaceColor = colorScheme.primaryContainer.withValues(
      alpha: isDark ? 0.34 : 0.72,
    );
    final borderColor = colorScheme.primary.withValues(
      alpha: isDark ? 0.18 : 0.24,
    );
    final iconColor = colorScheme.primary;
    final labelColor = colorScheme.onPrimaryContainer;

    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Colors.transparent,
        elevation: 0,
        shadowColor: colorScheme.primary.withValues(alpha: 0.12),
        child: InkWell(
          key: const Key('learning_plan_free_play_button'),
          onTap: onPressed,
          borderRadius: BorderRadius.circular(28),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              color: surfaceColor,
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.headphones_rounded, size: 18, color: iconColor),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                    color: labelColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
