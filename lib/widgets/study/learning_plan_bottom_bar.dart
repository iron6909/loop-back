/// 学习计划页底部操作栏：开始 / 继续 / 暂停 / 恢复 / 重置学习进度。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/learning_progress.dart';
import '../../providers/learning_progress_provider.dart';
import '../../theme/app_theme.dart';
import '../guide_flow.dart';

/// 底部固定按钮 — 根据进度显示不同形态：
///
/// - 未开始：单按钮「开始学习」（[onPressed] 为 null 时禁用）。
/// - 进行中（未暂停）：Row[Expanded 1:暂停学习 | Expanded 2:继续学习]，比例 1:2。
/// - 进行中（已暂停）：单按钮「恢复学习」，点击直接恢复（不弹窗），随后 UI 自动
///   回到 Row 形态。
/// - 已学完：单按钮「重置学习进度」，点击弹窗确认后清除全部进度。
class LearningPlanBottomBar extends ConsumerWidget {
  final AppLocalizations l10n;
  final LearningProgress? progress;
  final String audioItemId;
  final String audioItemName;
  final VoidCallback? onPressed;
  final GuideStep? startLearningStep;
  final GuideStep? pauseLearningStep;

  const LearningPlanBottomBar({
    required this.l10n,
    required this.audioItemId,
    required this.audioItemName,
    this.progress,
    required this.onPressed,
    this.startLearningStep,
    this.pauseLearningStep,
  });

  Future<void> _confirmAndPause(BuildContext context, WidgetRef ref) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.pauseLearningConfirmTitle),
        content: Text(l10n.pauseLearningConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.pauseLearning),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ref
          .read(learningProgressNotifierProvider.notifier)
          .pauseProgress(audioItemId);
    }
  }

  Future<void> _resume(WidgetRef ref) {
    return ref
        .read(learningProgressNotifierProvider.notifier)
        .resumeProgress(audioItemId);
  }

  /// 已学完状态：重置学习进度（与音频列表菜单的「重置学习进度」逻辑一致）
  Future<void> _confirmAndReset(BuildContext context, WidgetRef ref) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.resetLearningProgressConfirmTitle),
        content: Text(l10n.resetLearningProgressConfirmMessage(audioItemName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ref
          .read(learningProgressNotifierProvider.notifier)
          .resetProgress(audioItemId);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.resetLearningProgressDone)));
      }
    }
  }

  Widget _wrap(BuildContext context, Widget body) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.m),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(top: false, child: body),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasProgress = progress?.isStarted ?? false;
    final isPaused = progress?.isPaused ?? false;
    final isCompleted = progress?.isCompleted ?? false;

    // 已学完：只显示「重置学习进度」按钮，不再提供暂停/继续。
    if (isCompleted) {
      final theme = Theme.of(context);
      return _wrap(
        context,
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: () => _confirmAndReset(context, ref),
            icon: Icon(Icons.restart_alt, color: theme.colorScheme.error),
            label: Text(
              l10n.resetLearningProgress,
              style: TextStyle(color: theme.colorScheme.error),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
      );
    }

    // 暂停态：单按钮，文案合并「已暂停 · 恢复学习」，点击直接恢复。
    // 用 tonal 灰底突出当前是暂停态，与正常态的主色「继续学习」区分。
    if (hasProgress && isPaused) {
      final theme = Theme.of(context);
      return _wrap(
        context,
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonal(
            onPressed: () => _resume(ref),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              foregroundColor: theme.colorScheme.onSurfaceVariant,
            ),
            child: Text(
              '${l10n.pausedChipLabel} · ${l10n.resumeLearning}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      );
    }

    // 进行中（未暂停）：Row[暂停 | 继续] 1:2
    if (hasProgress) {
      final continueButton = FilledButton(
        onPressed: onPressed,
        child: Text(l10n.continueLearning),
      );
      final guidedContinue = startLearningStep != null
          ? GuideTarget(step: startLearningStep!, child: continueButton)
          : continueButton;
      final pauseButton = FilledButton.tonal(
        onPressed: () => _confirmAndPause(context, ref),
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest,
          foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        child: Text(
          l10n.pauseLearning,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
      final guidedPause = pauseLearningStep != null
          ? GuideTarget(step: pauseLearningStep!, child: pauseButton)
          : pauseButton;
      return _wrap(
        context,
        Row(
          children: [
            Expanded(flex: 3, child: guidedPause),
            const SizedBox(width: AppSpacing.m),
            Expanded(flex: 5, child: guidedContinue),
          ],
        ),
      );
    }

    // 未开始：单按钮「开始学习」
    final startButton = FilledButton(
      onPressed: onPressed,
      child: Text(l10n.startLearning),
    );
    final guidedStart = startLearningStep != null
        ? GuideTarget(step: startLearningStep!, child: startButton)
        : startButton;
    return _wrap(context, SizedBox(width: double.infinity, child: guidedStart));
  }
}
