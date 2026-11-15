/// 学习计划页顶部进度卡片：圆环进度 + 阶段文案 + 逾期徽章 + 音频元信息。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/enums.dart';
import '../../l10n/app_localizations.dart';
import '../../models/audio_item.dart';
import '../../models/learning_progress.dart';
import '../../providers/learning_plan_provider.dart';
import '../../providers/learning_progress_provider.dart';
import '../../services/subtitle_parser.dart';
import '../../theme/app_theme.dart';
import '../review/review_briefing_sheet.dart' show reviewStageLabel;
import 'progress_ring_painter.dart';
import 'study_info_chip.dart';

/// 顶部进度卡片 — 圆环进度 + 状态文字 + 逾期徽章 + 音频元信息
class PlanProgressCard extends ConsumerWidget {
  final AppLocalizations l10n;
  final LearningProgress? progress;
  final AudioItem? audioItem;
  final DateTime now;

  const PlanProgressCard({
    required this.l10n,
    this.progress,
    this.audioItem,
    required this.now,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 没有 audioItem 时（理论不出现，因 progress 同源）退化到全局默认 plan。
    final plan = audioItem == null
        ? ref.watch(learningPlanProvider)
        : ref.watch(learningPlanForAudioProvider(audioItem!.id));
    final completedKeys = audioItem == null
        ? const <String>{}
        : ref
              .watch(learningProgressNotifierProvider)
              .completionsFor(audioItem!.id);
    final percent = progress?.progressPercent(plan, completedKeys) ?? 0.0;
    final percentText = '${(percent * 100).round()}%';

    final isInProgress = _isInProgress();
    final overdueText = _getOverdueText();
    // 第一行徽章：进行中显示 In Progress，否则显示逾期
    final badgeText = isInProgress ? l10n.learningInProgress : overdueText;
    final badgeIsError = !isInProgress && overdueText != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.l),
        child: Row(
          children: [
            // 左侧：圆环进度
            SizedBox(
              width: 64,
              height: 64,
              child: CustomPaint(
                painter: ProgressRingPainter(
                  progress: percent,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  progressColor: theme.colorScheme.primary,
                ),
                child: Center(
                  child: Text(
                    percentText,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.m),
            // 右侧：三行信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 第一行：大阶段 + 逾期徽章
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _getStageText(),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (badgeText != null) ...[
                        const SizedBox(width: AppSpacing.s),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: badgeIsError
                                ? theme.colorScheme.error.withValues(alpha: 0.1)
                                : theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            badgeText,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 10,
                              color: badgeIsError
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.onSurfaceVariant,
                              fontWeight: badgeIsError
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  // 第二行：子阶段
                  if (_getSubStageText() case final subStage?) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      subStage,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  // 第三行：音频元信息
                  if (audioItem != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    _buildAudioInfo(theme),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建音频元信息行
  Widget _buildAudioInfo(ThemeData theme) {
    final item = audioItem!;
    final chips = <Widget>[];

    // 内容异常警告（损坏 / 静音）放在首位，最醒目。
    final contentWarningLabel = _contentWarningLabel(item.contentStatus);
    if (contentWarningLabel != null) {
      chips.add(_buildContentWarningChip(theme, contentWarningLabel));
    }
    if (item.totalDuration > 0) {
      chips.add(
        StudyInfoChip(
          icon: Icons.timer_outlined,
          label: SubtitleParser.formatDuration(
            Duration(seconds: item.totalDuration),
          ),
          theme: theme,
        ),
      );
    }
    if (item.sentenceCount > 0) {
      chips.add(
        StudyInfoChip(
          icon: Icons.format_list_numbered,
          label: l10n.sentenceCountLabel(item.sentenceCount),
          theme: theme,
        ),
      );
    }
    if (item.wordCount > 0) {
      chips.add(
        StudyInfoChip(
          icon: Icons.text_fields,
          label: l10n.wordCountLabel(item.wordCount),
          theme: theme,
        ),
      );
    }

    if (chips.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: AppSpacing.s,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: chips,
    );
  }

  /// 内容异常警告徽章，与音频列表项的警告徽章风格一致。
  Widget _buildContentWarningChip(ThemeData theme, String label) {
    final color = theme.colorScheme.error;
    return Container(
      key: const Key('learning_plan_content_warning_badge'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }

  String? _contentWarningLabel(AudioContentStatus? status) {
    return switch (status) {
      AudioContentStatus.damaged => l10n.audioContentDamagedWarning,
      AudioContentStatus.silent => l10n.audioContentSilentWarning,
      AudioContentStatus.ok || null => null,
    };
  }

  /// 第一行：大阶段文字
  String _getStageText() {
    if (progress == null || !progress!.isStarted) {
      return l10n.learningPlanNotStarted;
    }
    if (progress!.isCompleted) {
      return l10n.learningCompleted;
    }
    return reviewStageLabel(l10n, progress!.currentStage);
  }

  /// 第二行：子阶段文字（未开始/已完成时返回 null）
  String? _getSubStageText() {
    if (progress == null || !progress!.isStarted || progress!.isCompleted) {
      return null;
    }
    final subStageName = switch (progress!.currentSubStage) {
      SubStageType.blindListen => l10n.stepBlindListening,
      SubStageType.intensiveListen => l10n.stepIntensiveListening,
      SubStageType.listenAndRepeat => l10n.stepShadowing,
      SubStageType.retell => l10n.stepRetelling,
      SubStageType.reviewDifficultPractice => l10n.reviewDifficultPracticeTitle,
      SubStageType.reviewRetellParagraph => l10n.stepRetelling,
      SubStageType.reviewRetellSummary => l10n.stepRetelling,
    };
    return subStageName;
  }

  /// 是否正在学习中（当前阶段已完成至少 1 个子阶段）
  bool _isInProgress() {
    if (progress == null || !progress!.isStarted || progress!.isCompleted) {
      return false;
    }
    return progress!.currentSubStageIndex > 0;
  }

  /// 获取逾期文案（未逾期返回 null）
  String? _getOverdueText() {
    if (progress == null || !progress!.isReviewOverdueAt(now)) return null;
    final overdue = progress!.overdueDurationAt(now);
    if (overdue == null || overdue.inDays > 7) return l10n.reviewDue;
    if (overdue.inDays > 0) return l10n.overdueDays(overdue.inDays);
    final hours = overdue.inHours.clamp(1, 999);
    return l10n.overdueHours(hours);
  }
}
