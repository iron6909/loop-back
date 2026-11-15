/// 无字幕提醒横幅：提示用户先补字幕，并给出直接打开字幕管理的入口。
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../guide_flow.dart';

class NoTranscriptBanner extends StatelessWidget {
  const NoTranscriptBanner({
    super.key,
    required this.l10n,
    required this.addSubtitleStep,
    required this.onManageSubtitles,
  });

  final AppLocalizations l10n;

  /// 新手引导步骤：指向「添加字幕」按钮。
  final GuideStep addSubtitleStep;

  /// 打开字幕管理；由页面注入，横幅本身不碰 provider 与路由。
  final VoidCallback onManageSubtitles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.m),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: theme.colorScheme.onErrorContainer,
              size: 24,
            ),
            const SizedBox(width: AppSpacing.s),
            Expanded(
              child: Text(
                l10n.noTranscriptWarning,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.s),
            GuideTarget(
              step: addSubtitleStep,
              child: FilledButton.icon(
                onPressed: onManageSubtitles,
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.addSubtitle),
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.onErrorContainer,
                  foregroundColor: theme.colorScheme.errorContainer,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.m,
                    vertical: AppSpacing.xs,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
