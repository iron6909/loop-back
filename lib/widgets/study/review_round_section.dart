/// 学习计划「复习轮次」区块：各轮次的子步骤卡片与提前解锁入口。
///
/// 只负责展示与把点击转成回调；任务启动由页面注入的回调完成。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../database/enums.dart';
import '../../l10n/app_localizations.dart';
import '../../models/learning_progress.dart';
import '../../models/media_learning_startup.dart';
import '../../models/media_load_result.dart';
import '../../models/retell_settings.dart';
import '../../models/stage_settings_overrides.dart';
import '../../models/study_stage.dart';
import '../../providers/audio_engine/audio_engine_provider.dart';
import '../../providers/audio_library_provider.dart';
import '../../providers/audio_sentences_provider.dart';
import '../../providers/blind_listen_prefs_provider.dart';
import '../../providers/difficult_practice_prefs_provider.dart';
import '../../providers/learning_plan_provider.dart';
import '../../providers/learning_plan_stage_providers.dart';
import '../../providers/learning_progress_provider.dart';
import '../../providers/learning_session/learning_session_provider.dart';
import '../../providers/listening_practice/listening_practice_provider.dart';
import '../../providers/settings_provider.dart';
import '../../router/app_router.dart';
import '../../theme/app_theme.dart';
import '../../utils/blind_listen_duration_estimator.dart';
import '../../utils/learning_duration_estimator.dart';
import '../../utils/learning_practice_navigation.dart';
import '../../utils/paragraph_grouping.dart';
import '../../utils/playback_speed_default.dart';
import '../../utils/study_stage_ordering.dart';
import '../../utils/time_format.dart';
import '../blind_listen_paragraph_sheet.dart';
import '../retell/retell_briefing_sheet.dart';
import '../review/review_briefing_sheet.dart';
import '../speech_permission_dialog.dart';
import 'briefing_defaults.dart';
import 'plan_step_cards.dart';
import 'stage_header_row.dart';
import 'study_stage_icons.dart';
import 'study_stage_visuals.dart';

/// 单个复习轮次的数据模型
class ReviewStageData {
  final String name;
  final LearningStage stage;

  const ReviewStageData({required this.name, required this.stage});
}

/// 单个复习轮次区块（与首次学习同级）
///
/// 视觉与首次学习区块保持一致：标题行可独立折叠/展开，展开后显示子阶段。
class ReviewRoundSection extends ConsumerWidget {
  final AppLocalizations l10n;
  final LearningProgress? progress;
  final ReviewStageData review;
  final DateTime now;

  /// 合集 ID（导航用）
  final String? collectionId;

  /// 音频项 ID（导航用）
  final String audioItemId;
  final bool isExpanded;
  final VoidCallback onToggle;

  /// 点击当前进行中步骤的回调（效果同底部「开始学习」），不可启动时为 null
  final VoidCallback? onStartCurrentStage;

  const ReviewRoundSection({
    required this.l10n,
    this.progress,
    required this.review,
    required this.now,
    required this.collectionId,
    required this.audioItemId,
    required this.isExpanded,
    required this.onToggle,
    this.onStartCurrentStage,
  });

  /// 使用统计与任务卡片共用的阶段展示定义，仅补充复习描述。
  PlanStepData _stepDataForStage(StudyStage stage, String description) {
    final visual = studyStageVisual(stage, l10n);
    return PlanStepData(
      icon: visual.icon,
      iconColor: visual.iconColor,
      name: visual.name,
      description: description,
    );
  }

  /// 计算本轮次「已完成」子步骤数（基于真实完成历史 [completedKeys]）。
  int _completedSubStageCount(Set<String> completedKeys) {
    int count = 0;
    for (final sub in review.stage.allSubStages) {
      if (completedKeys.contains('${review.stage.key}:${sub.key}')) count += 1;
    }
    return count;
  }

  /// 当前复习轮次时间文案（仅当前轮次显示）。
  ///
  /// 展示优先级：已有进度→"学习中" > 未到时间倒计时 > 逾期提示 > 可复习。
  String? _reviewTimingText(
    BuildContext context, {
    required Set<String> completedKeys,
  }) {
    if (progress == null) return null;
    if (!progress!.isCurrentStage(review.stage)) return null;

    // 已有进度（至少完成 1 个子阶段）→ 显示"学习中"
    if (_completedSubStageCount(completedKeys) > 0) {
      return l10n.learningInProgress;
    }

    final nextReview = progress!.nextReviewAt;
    if (nextReview == null) return null;

    // 与锁定判定同源（isReviewReadyAt 对手动解锁短路），避免手动解锁后
    // 按钮已消失、倒计时文案却仍显示的不一致。
    if (!progress!.isReviewReadyAt(now) && now.isBefore(nextReview)) {
      final diff = nextReview.difference(now);
      if (diff.inDays > 0) {
        return l10n.reviewUnlockIn(diff.inDays);
      }
      return l10n.reviewUnlockInHours(diff.inHours.clamp(1, 999));
    }

    if (progress!.isReviewOverdueAt(now)) {
      return _formatOverdueText(context, progress!.overdueDurationAt(now));
    }

    return l10n.reviewDue;
  }

  /// 逾期措辞：短期保留时间信息，长期只显示"待复习"。
  ///
  /// - 无时长 / >7天 → "待复习"
  /// - ≤7天 → "待复习 · X天前到期"
  /// - <1天 → "待复习 · X小时前到期"
  String _formatOverdueText(BuildContext context, Duration? overdue) {
    // 无时长信息或长期逾期（>7天）只显示"待复习"
    if (overdue == null || overdue.inDays > 7) {
      return l10n.reviewDue;
    }
    if (overdue.inDays > 0) {
      return l10n.overdueDays(overdue.inDays);
    }
    final hours = overdue.inHours.clamp(1, 999);
    return l10n.overdueHours(hours);
  }

  /// 复习子阶段名称与描述映射
  PlanStepData _subStageData(SubStageType subStage) {
    final retellSummaryVisual = studyRetellSummaryVisual(l10n);
    return switch (subStage) {
      SubStageType.blindListen => _stepDataForStage(
        StudyStage.blindListen,
        l10n.reviewBlindListenDesc,
      ),
      SubStageType.intensiveListen => _stepDataForStage(
        StudyStage.intensiveListen,
        l10n.stepIntensiveListeningDesc,
      ),
      SubStageType.listenAndRepeat => _stepDataForStage(
        StudyStage.listenAndRepeat,
        l10n.stepShadowingDesc,
      ),
      SubStageType.retell => _stepDataForStage(
        StudyStage.retell,
        l10n.stepRetellingDesc,
      ),
      SubStageType.reviewDifficultPractice => _stepDataForStage(
        StudyStage.reviewDifficultPractice,
        l10n.reviewDifficultPracticeDesc,
      ),
      SubStageType.reviewRetellParagraph => _stepDataForStage(
        StudyStage.retell,
        l10n.reviewRetellParagraphDesc,
      ),
      SubStageType.reviewRetellSummary => PlanStepData(
        icon: retellSummaryVisual.icon,
        iconColor: retellSummaryVisual.iconColor,
        name: retellSummaryVisual.name,
        description: l10n.reviewRetellSummaryDesc,
      ),
    };
  }

  /// 进入自由练习盲听模式（复习阶段的全文盲听）
  Future<void> _startFreePlayBlindListen(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final audioItem = ref
        .read(audioLibraryProvider.notifier)
        .getItemById(audioItemId);
    if (audioItem == null) return;
    final sentences = audioItem.isVideo
        ? await ref.read(audioSentencesProvider(audioItemId).future)
        : ref.read(listeningPracticeProvider).sentences;
    if (!context.mounted) return;
    if (sentences.isEmpty) return;

    // 按当前难句书签数实时重算难度，难度降低后速度随之回升
    final liveDifficulty = await ref
        .read(learningProgressNotifierProvider.notifier)
        .refreshDifficultyFromBookmarks(audioItemId, sentences.length);
    if (!context.mounted) return;

    final l10n = AppLocalizations.of(context)!;
    final estimatedDuration = estimateBlindListenSessionDuration(
      sentences: sentences,
      fullAudioDuration: ref.read(audioEngineProvider).totalDuration,
      skipSilenceEnabled: ref.read(appSettingsProvider).skipSilenceEnabled,
    );

    final smartSpeed = progress == null
        ? 1.0
        : defaultPlaybackSpeedFor(liveDifficulty, review.stage);
    final slot = stageSlotKey(StageSettingsSlots.blindListen, review.stage);
    final blindPrefs = ref.read(blindListenPrefsProvider.notifier);
    final defaults = blindPrefs.resolve(slot, smartSpeed: smartSpeed);
    final blindSeconds = blindPrefs.resolveTargetSeconds(
      slot,
      smartSeconds: -1,
    );
    showBlindListenParagraphSheet(
      context: context,
      sentences: sentences,
      estimatedDurationText: estimatedDuration != null
          ? formatEstimatedDuration(l10n, estimatedDuration)
          : null,
      defaultPlaybackSpeed: defaults.playbackSpeed,
      defaultSeconds: blindSeconds,
      defaultPause: blindPauseChoiceFromSettings(defaults),
      onSelectionChanged: blindPrefsRecorder(ref, slot, defaults, blindSeconds),
      onStartPractice: (targetDuration, pause, playbackSpeed) async {
        final settings = ref
            .read(blindListenPrefsProvider.notifier)
            .resolve(slot, smartSpeed: smartSpeed);
        final paragraphs = groupSentencesIntoParagraphs(
          sentences,
          targetDuration,
        );
        await openBlindListenPractice(
          context: context,
          ref: ref,
          audioItem: audioItem,
          collectionId: collectionId,
          paragraphs: paragraphs,
          settings: settings,
          stage: review.stage,
          loadKey: '${audioItem.id}:blind-listen:${review.stage.key}:free-play',
          isFreePlay: true,
          catchUpStage: review.stage,
          catchUpSubStage: SubStageType.blindListen,
        );
      },
    );
  }

  /// 进入自由练习难句补练模式
  Future<void> _startFreePlayDifficultPractice(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final allowed = await ensureSpeechReadyForSubStage(
      context,
      ref,
      SubStageType.reviewDifficultPractice,
    );
    if (!allowed || !context.mounted) return;

    final audioItem = ref
        .read(audioLibraryProvider.notifier)
        .getItemById(audioItemId);
    if (audioItem == null) return;
    final sentences = audioItem.isVideo
        ? await ref.read(audioSentencesProvider(audioItemId).future)
        : ref.read(listeningPracticeProvider).sentences;
    if (sentences.isEmpty || !context.mounted) return;

    // 难句补练自由练习也按"先弹 briefing 含速度下拉"流程，与按计划学习对齐。
    final difficultDuration = sentences
        .where((s) => s.isBookmarked)
        .fold<Duration>(Duration.zero, (sum, s) => sum + s.duration);
    // 按当前难句书签数实时重算难度，难度降低后速度随之回升
    final liveDifficulty = await ref
        .read(learningProgressNotifierProvider.notifier)
        .refreshDifficultyFromBookmarks(audioItemId, sentences.length);
    if (!context.mounted) return;
    final smartSpeed = progress == null
        ? 1.0
        : defaultPlaybackSpeedFor(liveDifficulty, review.stage);
    final slot = stageSlotKey(
      StageSettingsSlots.reviewDifficultPractice,
      review.stage,
    );
    final dp = ref.read(difficultPracticePrefsProvider.notifier);
    final defaults = dp.resolve(slot, smartSpeed: smartSpeed);
    final estimated = estimateDifficultPracticeDuration(
      difficultSentenceDuration: difficultDuration,
      blindListenRepeatCount: defaults.isManualMode
          ? 1
          : defaults.blindListenRepeatCount,
      shadowReadingRepeatCount: defaults.isManualMode
          ? 1
          : defaults.shadowReadingRepeatCount,
    );
    showReviewBriefingSheet(
      context: context,
      stage: review.stage,
      subStage: SubStageType.reviewDifficultPractice,
      estimatedDuration: estimated,
      defaultPlaybackSpeed: defaults.playbackSpeed,
      defaultPause: difficultPauseChoiceFromSettings(defaults),
      onSelectionChanged: difficultPrefsRecorder(ref, slot, defaults),
      onStartPractice: (playbackSpeed, pause) async {
        final settings = ref
            .read(difficultPracticePrefsProvider.notifier)
            .resolve(slot, smartSpeed: smartSpeed);
        context.push(
          AppRoutes.reviewDifficultPractice(collectionId, audioItemId),
          extra: MediaLearningStartup(
            loadKey:
                '${audioItem.id}:review-difficult:${review.stage.key}:free-play',
            showVideoLoading: audioItem.isVideo,
            load: () async {
              final result = await ref
                  .read(learningSessionProvider.notifier)
                  .enterReviewDifficultPracticeMode(
                    audioItem,
                    sentences,
                    isFreePlay: true,
                    settings: settings,
                    stage: review.stage,
                  );
              if (result != MediaLoadResult.ready) return result;
              ref
                  .read(learningSessionProvider.notifier)
                  .setCatchUp(
                    review.stage,
                    SubStageType.reviewDifficultPractice,
                  );
              return result;
            },
            cancel: () => ref
                .read(learningSessionProvider.notifier)
                .cancelReviewDifficultPracticeEntry(),
          ),
        );
      },
    );
  }

  /// 进入自由练习复述模式（段落复述 / 全文复述）
  Future<void> _startFreePlayRetell(
    BuildContext context,
    WidgetRef ref, {
    required bool isSummary,
  }) async {
    final allowed = await ensureSpeechReadyForSubStage(
      context,
      ref,
      isSummary
          ? SubStageType.reviewRetellSummary
          : SubStageType.reviewRetellParagraph,
    );
    if (!allowed || !context.mounted) return;

    final audioItem = ref
        .read(audioLibraryProvider.notifier)
        .getItemById(audioItemId);
    if (audioItem == null) return;
    final sentences = audioItem.isVideo
        ? await ref.read(audioSentencesProvider(audioItemId).future)
        : ref.read(listeningPracticeProvider).sentences;
    if (!context.mounted || sentences.isEmpty) return;

    final catchUpSub = isSummary
        ? SubStageType.reviewRetellSummary
        : SubStageType.reviewRetellParagraph;

    if (isSummary) {
      // 全文复述：全文作为单个段落，无需选择时长
      await openRetellPractice(
        context: context,
        ref: ref,
        audioItem: audioItem,
        collectionId: collectionId,
        paragraphs: [sentences],
        loadKey: '${audioItem.id}:retell-summary:${review.stage.key}:free-play',
        isFreePlay: true,
        catchUpStage: review.stage,
        catchUpSubStage: catchUpSub,
      );
      return;
    }

    // 段落复述：弹出简报面板让用户选择段落时长（预估时长由 sheet 内部按真实公式动态计算）
    final progressForRetell = ref
        .read(learningProgressNotifierProvider)
        .progressMap[audioItemId];
    // 按当前难句书签数实时重算难度，难度降低后速度/可见词比例随之调整
    final liveDifficulty = await ref
        .read(learningProgressNotifierProvider.notifier)
        .refreshDifficultyFromBookmarks(audioItemId, sentences.length);
    if (!context.mounted) return;
    final slot = stageSlotKey(StageSettingsSlots.retell, review.stage);
    final prefill = retellBriefingDefaults(
      ref,
      slot,
      smartSpeed: progressForRetell != null
          ? defaultPlaybackSpeedFor(liveDifficulty, review.stage)
          : 1.0,
      smartRatio: KeywordRatio.forDifficultyAndStage(
        liveDifficulty,
        review.stage,
      ),
      smartSeconds: retellDefaultSeconds(review.stage),
    );
    showRetellBriefingSheet(
      context: context,
      sentences: sentences,
      defaultSeconds: prefill.seconds,
      defaultKeywordRatio: progressForRetell != null ? prefill.ratio : null,
      defaultPlaybackSpeed: prefill.speed,
      repeatCount: prefill.settings.isManualMode
          ? 1
          : prefill.settings.repeatCount,
      defaultPause: prefill.pause,
      onSelectionChanged: retellPrefsRecorder(ref, slot, prefill.settings),
      onStartPractice: (targetDuration, pause, keywordRatio, playbackSpeed) async {
        final paragraphs = groupSentencesIntoParagraphs(
          sentences,
          targetDuration,
        );
        await openRetellPractice(
          context: context,
          ref: ref,
          audioItem: audioItem,
          collectionId: collectionId,
          paragraphs: paragraphs,
          loadKey:
              '${audioItem.id}:retell-paragraph:${review.stage.key}:free-play',
          isFreePlay: true,
          catchUpStage: review.stage,
          catchUpSubStage: catchUpSub,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final plan = ref.watch(learningPlanForAudioProvider(audioItemId));
    final stageCompletedAtMap =
        ref
            .watch(reviewStageCompletionTimesProvider(audioItemId))
            .valueOrNull ??
        const <String, DateTime>{};
    final completedKeys = ref
        .watch(learningProgressNotifierProvider)
        .completionsFor(audioItemId);
    // 迭代顺序 = 当前 plan 顺序 + 历史外延项（已完成 / 已跳过但不在当前 plan 内）。
    // 例如 review28 v1 用户完成了 reviewRetellSummary 后切到 v2 不会发生（v1 用户
    // 该 stage 有 completion 仍走 v1 plan），但 helper 防御性兜底。
    final subStages = orderedSubStagesForDisplay(
      plan: plan,
      stage: review.stage,
      completedKeys: completedKeys,
      skippedKeys: progress?.skippedSubStageKeys ?? const {},
    );
    final completedCount = _completedSubStageCount(completedKeys);
    final timingText = _reviewTimingText(context, completedKeys: completedKeys);
    final isCompleted = progress?.isStageCompleted(review.stage) ?? false;
    final isCurrent = progress?.isCurrentStage(review.stage) ?? false;
    final isFuture = !isCompleted && !isCurrent;
    final completedAt = stageCompletedAtMap[review.stage.key];
    // 标题行文案优先级：
    // 1. 已完成轮次显示相对完成时间
    // 2. 当前轮次显示真实倒计时 / 待复习 / 逾期
    // 3. 未来轮次不显示固定时间标签，避免误导为累计里程碑
    final statusText = isCompleted
        ? (completedAt == null
              ? null
              : formatCompletedStageTimeLabel(context, completedAt))
        : timingText;
    // 标题颜色：已完成→绿色，当前→默认，未来→弱化
    final titleColor = isCompleted
        ? Colors.green
        : isFuture
        ? theme.colorScheme.onSurfaceVariant
        : null;
    // 状态文案颜色：已完成→绿色，其余状态→弱化前景色。
    final statusColor = isCompleted
        ? Colors.green
        : theme.colorScheme.onSurfaceVariant;
    final reviewIconColor = isCompleted
        ? Colors.green
        : isFuture
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSurface;
    // 当前轮次锁定且未暂停 → 显示可点解锁药丸（倒计时并入药丸，不再挤在标题行）
    final showUnlockPill =
        isCurrent &&
        !(progress?.isPaused ?? false) &&
        (progress?.isReviewLockedAt(now) ?? false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Opacity(
          // 未开始（锁定）轮次进一步弱化，避免抢夺当前/已完成轮次的注意力
          opacity: isFuture ? 0.45 : 1.0,
          child: StudyStageHeaderRow(
            keyPrefix: 'learning_plan_stage_${review.stage.key}',
            leadingIcon: SvgPicture.asset(
              studyRefreshIconAsset,
              width: 20,
              height: 20,
              colorFilter: ColorFilter.mode(reviewIconColor, BlendMode.srcIn),
            ),
            title: review.name,
            titleColor: titleColor,
            statusIcon: isCompleted
                ? SvgPicture.asset(
                    studyCheckCircleIconAsset,
                    width: 18,
                    height: 18,
                    colorFilter: const ColorFilter.mode(
                      Colors.green,
                      BlendMode.srcIn,
                    ),
                  )
                : isCurrent
                ? SvgPicture.asset(
                    studyCalendarIconAsset,
                    width: 18,
                    height: 18,
                  )
                : SvgPicture.asset(
                    studyLockIconAsset,
                    width: 18,
                    height: 18,
                    colorFilter: ColorFilter.mode(
                      theme.colorScheme.onSurfaceVariant,
                      BlendMode.srcIn,
                    ),
                  ),
            // 状态文案内联到标题行：已完成显示完成时间，当前显示真实状态，
            // 未来轮次不显示固定“After X days”，但仍保留状态文案列宽。
            statusText: statusText,
            statusTextColor: statusColor,
            progressText: l10n.stepProgress(completedCount, subStages.length),
            progressColor: isCompleted
                ? Colors.green
                : theme.colorScheme.onSurfaceVariant,
            isExpanded: isExpanded,
            onTap: onToggle,
          ),
        ),
        // 当前轮次锁定且未暂停时显示「立即解锁」药丸按钮：倒计时是标题行的
        // 纯展示 label，解锁是独立按钮，两者分离避免歧义（解锁写 manualUnlockAt，
        // 不篡改完成时间，后续轮次仍按实际完成时间顺延）。
        if (showUnlockPill)
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.xl,
              top: AppSpacing.xs,
            ),
            child: Material(
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => ref
                    .read(learningProgressNotifierProvider.notifier)
                    .unlockCurrentReview(audioItemId),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.m,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SvgPicture.asset(
                        studyUnlockIconAsset,
                        width: 14,
                        height: 14,
                        colorFilter: ColorFilter.mode(
                          theme.colorScheme.primary,
                          BlendMode.srcIn,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        l10n.unlockReviewNow,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (isExpanded) ...[
          const SizedBox(height: AppSpacing.s),
          Column(
            children: List.generate(subStages.length, (index) {
              final subStage = subStages[index];
              final subStageData = _subStageData(subStage);
              final isCompleted =
                  progress?.isSubStageCompleted(
                    review.stage,
                    subStage,
                    completedKeys,
                  ) ??
                  false;
              final isCurrent =
                  progress?.isCurrentSubStage(review.stage, subStage) ?? false;
              final isSkipped =
                  progress?.isSubStageSkipped(review.stage, subStage) ?? false;

              // 难句补练步骤：显示难句数量或自动完成提示
              String? subtitle;
              if (subStage == SubStageType.reviewDifficultPractice) {
                final bookmarkCount =
                    ref.watch(bookmarkCountProvider(audioItemId)).valueOrNull ??
                    0;
                if (isCompleted && bookmarkCount == 0) {
                  subtitle = l10n.autoCompletedNoDifficultReview;
                } else if (bookmarkCount > 0) {
                  subtitle = l10n.difficultSentenceCount(bookmarkCount);
                }
              }

              // 已完成、已跳过（含当前阶段内跳过）或过去阶段的子步骤都支持点击进入自由练习。
              // （跳过的步骤用户随时可补做，不必等大阶段推进）
              final isPast =
                  progress != null &&
                  review.stage.index < progress!.currentStage.index;
              final canFreePlay = isCompleted || isSkipped || isPast;
              VoidCallback? onTap;
              if (canFreePlay) {
                // 无难句自动完成的补练步骤：点击只显示提示
                final bookmarkCount =
                    ref.watch(bookmarkCountProvider(audioItemId)).valueOrNull ??
                    0;
                if (subStage == SubStageType.reviewDifficultPractice &&
                    bookmarkCount == 0) {
                  onTap = () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(l10n.autoCompletedNoDifficultReview),
                      ),
                    );
                  };
                } else {
                  onTap = switch (subStage) {
                    SubStageType.blindListen => () => _startFreePlayBlindListen(
                      context,
                      ref,
                    ),
                    SubStageType.reviewDifficultPractice =>
                      () => _startFreePlayDifficultPractice(context, ref),
                    SubStageType.reviewRetellParagraph =>
                      () =>
                          _startFreePlayRetell(context, ref, isSummary: false),
                    SubStageType.reviewRetellSummary =>
                      () => _startFreePlayRetell(context, ref, isSummary: true),
                    _ => null,
                  };
                }
              }

              // 当前进行中的步骤：点击等同底部「开始学习」
              if (isCurrent) {
                onTap = onStartCurrentStage;
              }

              return PlanStepCard(
                stepNumber: index + 1,
                icon: subStageData.icon,
                iconColor: subStageData.iconColor,
                name: subStageData.name,
                description: subStageData.description,
                isCompleted: isCompleted,
                isCurrent: isCurrent,
                isSkipped: isSkipped,
                isFirst: index == 0,
                isLast: index == subStages.length - 1,
                subtitle: subtitle,
                onTap: onTap,
              );
            }),
          ),
        ],
      ],
    );
  }
}
