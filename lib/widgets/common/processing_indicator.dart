/// 处理中指示器（共享组件）
///
/// 56×56 圆形，内部显示旋转加载动画。
/// 用于录音评估中、数据加载中等场景。
///
/// **纯展示组件**：不依赖任何 Provider。
library;

import 'package:flutter/material.dart';

/// 处理中指示器
class ProcessingIndicator extends StatelessWidget {
  /// 提示文字（null 则不显示）
  final String? text;

  const ProcessingIndicator({super.key, this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (text != null) ...[
          Text(
            text!,
            // 固定高度槽位里的提示只占一行，长文案省略而不撑破布局。
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 8),
        ],
        SizedBox(
          width: 56,
          height: 56,
          child: Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: theme.colorScheme.primary.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
