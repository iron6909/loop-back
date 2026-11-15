/// 图标 + 文案的小号元信息标签（学习计划进度卡片使用）。
library;

import 'package:flutter/material.dart';

/// 音频信息行 — 显示时长、句子数、单词数
/// 单个信息标签
class StudyInfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final ThemeData theme;

  const StudyInfoChip({
    required this.icon,
    required this.label,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: theme.colorScheme.outline),
        const SizedBox(width: 3),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }
}
