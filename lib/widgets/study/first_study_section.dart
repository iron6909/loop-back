/// 学习计划「首次学习」区块：4 个子步骤卡片 + 自由练习入口 + 完成状态。
///
/// 只负责展示与把点击转成回调；任务启动由页面注入的回调完成。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../database/enums.dart';
import '../../database/providers.dart';
import '../../features/rating_prompt/domain/rating_prompt_policy.dart';
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
import '../../providers/intensive_listen_prefs_provider.dart';
import '../../providers/learning_plan_provider.dart';
import '../../providers/learning_plan_stage_providers.dart';
import '../../providers/learning_progress_provider.dart';
import '../../providers/learning_session/learning_session_provider.dart';
import '../../providers/learning_session/sentence_playback_engine.dart';
import '../../providers/listen_and_repeat/listen_and_repeat_controller.dart';
import '../../providers/listening_practice/bookmark_manager.dart';
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
import '../intensive_listen/intensive_listen_briefing_sheet.dart';
import '../listen_and_repeat/listen_and_repeat_briefing_sheet.dart';
import '../retell/retell_briefing_sheet.dart';
import '../review/review_briefing_sheet.dart';
import '../speech_permission_dialog.dart';
import 'briefing_defaults.dart';
import 'plan_step_cards.dart';
import 'stage_header_row.dart';
import 'study_stage_icons.dart';
import 'study_stage_visuals.dart';

/// 首次学习区域 — 默认展开，显示 4 个步骤
///
/// 已完成的盲听步骤支持点击进入自由练习模式。
class FirstStudySection extends ConsumerWidget {
  final AppLocalizations l10n;
  final LearningProgress? progress;

  /// 合集 ID（导航用，从独立音频路由进入时为 null）
  final String? collectionId;

  /// 音频项 ID（导航用）
  final String audioItemId;

  /// 是否展开
  final bool isExpanded;

  /// 折叠/展开切换回调
  final VoidCallback onToggle;

  /// 点击当前进行中步骤的回调（效果同底部「开始学习」），不可启动时为 null
  final VoidCallback? onStartCurrentStage;

  const FirstStudySection({
    required this.l10n,
    this.progress,
    required this.collectionId,
    required this.audioItemId,
    required this.isExpanded,
    required this.onToggle,
    this.onStartCurrentStage,
  });

  /// 使用统计与任务卡片共用的阶段展示定义，仅补充首次学习描述。
  PlanStepData _stepDataForStage(StudyStage stage, String description) {
    final visual = studyStageVisual(stage, l10n);
    return PlanStepData(
      icon: visual.icon,
      iconColor: visual.iconColor,
      name: visual.name,
      description: description,
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
    final completedCount =
        progress?.completedFirstStudySteps(plan, completedKeys) ?? 0;
    final firstLearnStage = LearningStage.firstLearn;
    final isFirstLearnCompleted =
        progress?.isStageCompleted(LearningStage.firstLearn) ?? false;
    final firstLearnCompletedAt =
        stageCompletedAtMap[LearningStage.firstLearn.key] ??
        progress?.firstLearnCompletedAt;
    final firstLearnStatusText =
        isFirstLearnCompleted && firstLearnCompletedAt != null
        ? formatCompletedStageTimeLabel(context, firstLearnCompletedAt)
        : null;

    /// 子步骤的 UI 数据映射
    final stepDataMap = {
      SubStageType.blindListen: _stepDataForStage(
        StudyStage.blindListen,
        l10n.stepBlindListeningDesc,
      ),
      SubStageType.intensiveListen: _stepDataForStage(
        StudyStage.intensiveListen,
        l10n.stepIntensiveListeningDesc,
      ),
      SubStageType.listenAndRepeat: _stepDataForStage(
        StudyStage.listenAndRepeat,
        l10n.stepShadowingDesc,
      ),
      SubStageType.retell: _stepDataForStage(
        StudyStage.retell,
        l10n.stepRetellingDesc,
      ),
    };

    // 迭代顺序 = 当前 plan 顺序 + 历史外延项（已完成或已跳过但不在当前 plan 内）。
    // firstLearn 没有 plan 变体，但 helper 统一处理便于复用。
    final subStages = orderedSubStagesForDisplay(
      plan: plan,
      stage: firstLearnStage,
      completedKeys: completedKeys,
      skippedKeys: progress?.skippedSubStageKeys ?? const {},
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题行（可点击展开/折叠）
        StudyStageHeaderRow(
          keyPrefix: 'learning_plan_stage_first_learn',
          leadingIcon: SvgPicture.asset(
            studyReadingIconAsset,
            width: 20,
            height: 20,
          ),
          title: l10n.firstStudy,
          titleColor: isFirstLearnCompleted ? Colors.green : null,
          statusIcon: isFirstLearnCompleted
              ? SvgPicture.asset(
                  studyCheckCircleIconAsset,
                  width: 18,
                  height: 18,
                  colorFilter: const ColorFilter.mode(
                    Colors.green,
                    BlendMode.srcIn,
                  ),
                )
              : progress?.isCurrentStage(LearningStage.firstLearn) ?? false
              ? SvgPicture.asset(studyCalendarIconAsset, width: 18, height: 18)
              : SvgPicture.asset(
                  studyLockIconAsset,
                  width: 18,
                  height: 18,
                  colorFilter: ColorFilter.mode(
                    theme.colorScheme.onSurfaceVariant,
                    BlendMode.srcIn,
                  ),
                ),
          statusText: firstLearnStatusText,
          statusTextColor: Colors.green,
          progressText: l10n.stepProgress(completedCount, subStages.length),
          progressColor: isFirstLearnCompleted
              ? Colors.green
              : theme.colorScheme.onSurfaceVariant,
          isExpanded: isExpanded,
          onTap: onToggle,
        ),
        // 展开的步骤列表（无动画，直接切换）
        if (isExpanded) ...[
          const SizedBox(height: AppSpacing.s),
          Column(
            children: List.generate(subStages.length, (index) {
              final subStage = subStages[index];
              final stepData = stepDataMap[subStage]!;
              final isCompleted =
                  progress?.isSubStageCompleted(
                    firstLearnStage,
                    subStage,
                    completedKeys,
                  ) ??
                  false;
              final isCurrent =
                  progress?.isCurrentSubStage(firstLearnStage, subStage) ??
                  false;
              final isSkipped =
                  progress?.isSubStageSkipped(firstLearnStage, subStage) ??
                  false;

              // 各步骤显示完成统计
              String? subtitle;
              if (subStage == SubStageType.blindListen) {
                // 盲听：仅显示已听遍数（难度在逐句精听完成时自动判定，盲听不再展示）
                final passCount = progress?.blindListenPassCount ?? 0;
                if (passCount > 0) {
                  subtitle = l10n.blindListenPassInfo(passCount);
                }
              } else if (subStage == SubStageType.intensiveListen) {
                // 精听：仅当前或已完成步骤显示统计
                if (isCompleted || isCurrent) {
                  subtitle = _buildIntensiveListenSubtitle(ref, l10n);
                }
              } else if (subStage == SubStageType.listenAndRepeat) {
                // 跟读：统一显示难句数量和已练习遍数，零难句也保留练习记录。
                if (isCompleted || isCurrent) {
                  subtitle = _buildShadowingSubtitle(ref, l10n);
                }
              } else if (subStage == SubStageType.retell) {
                // 复述：仅当前或已完成步骤显示统计
                if (isCompleted || isCurrent) {
                  subtitle = _buildRetellSubtitle(l10n);
                }
              }

              // 已完成、已跳过（含当前阶段内跳过）或过去阶段的步骤都支持点击进入自由练习。
              // （跳过的步骤用户随时可补做，不必等大阶段推进）
              final isPast =
                  progress != null &&
                  firstLearnStage.index < progress!.currentStage.index;
              final canFreePlay = isCompleted || isSkipped || isPast;
              VoidCallback? onTap;
              if (canFreePlay && subStage == SubStageType.blindListen) {
                onTap = () => _startFreePlayBlindListen(context, ref);
              } else if (canFreePlay &&
                  subStage == SubStageType.intensiveListen) {
                onTap = () => _startFreePlayIntensiveListen(context, ref);
              } else if (canFreePlay &&
                  subStage == SubStageType.listenAndRepeat) {
                onTap = () => _startFreePlayListenAndRepeat(context, ref);
              } else if (canFreePlay && subStage == SubStageType.retell) {
                onTap = () => _startFreePlayRetell(context, ref);
              }

              // 当前进行中的步骤：点击等同底部「开始学习」
              if (isCurrent) {
                onTap = onStartCurrentStage;
              }

              return PlanStepCard(
                stepNumber: index + 1,
                icon: stepData.icon,
                iconColor: stepData.iconColor,
                name: stepData.name,
                description: stepData.description,
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

  /// 构建精听卡片副标题（实时难句数 + 总完成遍数）
  String? _buildIntensiveListenSubtitle(WidgetRef ref, AppLocalizations l10n) {
    final parts = <String>[];

    // 实时查询书签数量（难句数）
    final bookmarkCount =
        ref.watch(bookmarkCountProvider(audioItemId)).valueOrNull ?? 0;
    if (bookmarkCount > 0) {
      parts.add(l10n.difficultSentenceCount(bookmarkCount));
    }

    // 精听总完成遍数
    if (progress?.intensiveListenPassCount case final count? when count > 0) {
      parts.add(l10n.intensiveListenPassInfo(count));
    }

    return parts.isNotEmpty ? parts.join(' · ') : null;
  }

  /// 构建跟读卡片副标题（实时难句数 + 总完成遍数）
  String? _buildShadowingSubtitle(WidgetRef ref, AppLocalizations l10n) {
    final parts = <String>[];

    // 实时查询书签数量（难句数）
    final bookmarkCount =
        ref.watch(bookmarkCountProvider(audioItemId)).valueOrNull ?? 0;
    parts.add(l10n.listenAndRepeatBriefingDifficultCount(bookmarkCount));

    // 跟读总完成遍数
    if (progress?.shadowingPassCount case final count? when count > 0) {
      parts.add(l10n.shadowingPassInfo(count));
    }

    return parts.isNotEmpty ? parts.join(' · ') : null;
  }

  /// 进入自由练习盲听模式
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
    if (sentences.isEmpty) return;

    // 按当前难句书签数实时重算难度，难度降低后速度随之回升（与难句跟读/复述一致）
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

    // 全文盲听属于首次学习步骤,按 firstLearn 算默认速度;与按计划共用同一槽位偏好。
    const stage = LearningStage.firstLearn;
    final smartSpeed = progress != null
        ? defaultPlaybackSpeedFor(liveDifficulty, stage)
        : 1.0;
    final slot = stageSlotKey(StageSettingsSlots.blindListen, stage);
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
          stage: stage,
          loadKey: '${audioItem.id}:blind-listen:free-play',
          isFreePlay: true,
          catchUpStage: LearningStage.firstLearn,
          catchUpSubStage: SubStageType.blindListen,
        );
      },
    );
  }

  /// 进入自由练习精听模式（与按计划学习一致：先弹 briefing 含速度下拉）
  Future<void> _startFreePlayIntensiveListen(
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
    if (sentences.isEmpty || !context.mounted) return;

    final totalSentenceDuration = sentences.fold<Duration>(
      Duration.zero,
      (sum, s) => sum + s.duration,
    );

    // 与按计划入口同一份偏好真相源、同一槽位:预填、改完即记、进入设置完全一致。
    final slot = stageSlotKey(
      StageSettingsSlots.intensiveListen,
      LearningStage.firstLearn,
    );
    final prefs = ref.read(intensiveListenPrefsProvider.notifier);
    final defaults = prefs.resolve(slot, smartSpeed: 1.0);
    final intensiveEstimate = estimateIntensiveListenDuration(
      sentenceDuration: totalSentenceDuration,
      repeatCount: defaults.isManualMode ? 1 : defaults.repeatCount,
    );
    showIntensiveListenBriefingSheet(
      context: context,
      sentenceCount: sentences.length,
      estimatedDuration: intensiveEstimate,
      defaultPlaybackSpeed: defaults.playbackSpeed,
      defaultPause: intensivePauseChoiceFromSettings(defaults),
      onSelectionChanged: intensivePrefsRecorder(prefs, slot, defaults),
      onStartPractice: (playbackSpeed, pause) async {
        final notifier = ref.read(learningSessionProvider.notifier);
        final resolved = prefs.resolve(slot, smartSpeed: 1.0);
        if (!context.mounted) return;
        context.push(
          AppRoutes.intensiveListenPlayer(collectionId, audioItemId),
          extra: MediaLearningStartup(
            loadKey: '${audioItem.id}:free-play',
            load: () async {
              final result = await notifier.enterIntensiveListenMode(
                audioItem,
                sentences,
                isFreePlay: true,
                settings: resolved,
                settingsSlot: slot,
              );
              if (result == MediaLoadResult.ready) {
                // 补做语义：跳过的精听完成后回收为已完成。
                notifier.setCatchUp(
                  LearningStage.firstLearn,
                  SubStageType.intensiveListen,
                );
              }
              return result;
            },
            cancel: notifier.cancelIntensiveListenEntry,
            showVideoLoading: audioItem.isVideo,
          ),
        );
      },
    );
  }

  /// 进入自由练习跟读模式（与按计划学习一致：先弹 briefing 含速度下拉）
  Future<void> _startFreePlayListenAndRepeat(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final allowed = await ensureSpeechReadyForSubStage(
      context,
      ref,
      SubStageType.listenAndRepeat,
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

    final bookmarkDao = ref.read(bookmarkDaoProvider);
    final difficultIndices = await BookmarkManager.loadBookmarks(
      audioItemId,
      dao: bookmarkDao,
    );
    if (!context.mounted) return;
    // 按当前难句书签数实时重算难度（难句跟读入口最关键：用户练熟取消收藏后
    // 比例下降 → 难度降低 → 速度回升），同时用于跟读遍数 playCount。
    final liveDifficulty = await ref
        .read(learningProgressNotifierProvider.notifier)
        .refreshDifficultyFromBookmarks(audioItemId, sentences.length);
    if (!context.mounted) return;
    final smartPlayCount = targetPlayCountForDifficulty(liveDifficulty.index);
    final difficultDuration = difficultIndices.fold<Duration>(
      Duration.zero,
      (sum, idx) =>
          sum +
          (idx < sentences.length ? sentences[idx].duration : Duration.zero),
    );

    // 难句跟读只属于"首次学习"步骤,自由练习与按计划共用同一槽位偏好。
    final smartSpeed = progress != null
        ? defaultPlaybackSpeedFor(liveDifficulty, LearningStage.firstLearn)
        : 1.0;
    final slot = stageSlotKey(
      StageSettingsSlots.listenAndRepeat,
      LearningStage.firstLearn,
    );
    final prefs = ref.read(intensiveListenPrefsProvider.notifier);
    // 以难度遍数作为动态默认；用户改过循环次数时，简报与练习使用同一设置。
    final defaults = prefs.resolve(
      slot,
      smartSpeed: smartSpeed,
      smartRepeatCount: smartPlayCount,
    );
    final playCount = defaults.repeatCount;
    final repeatEstimate = playCount == 0
        ? null
        : difficultDuration * playCount * 2;
    final defaultScope = prefs.listenAndRepeatScopeFor(slot);
    final fullTextDuration = sentences.fold<Duration>(
      Duration.zero,
      (sum, sentence) => sum + sentence.duration,
    );
    showListenAndRepeatBriefingSheet(
      context: context,
      difficultCount: difficultIndices.length,
      fullTextCount: sentences.length,
      playCount: playCount,
      difficultEstimatedDuration: repeatEstimate,
      fullTextEstimatedDuration: playCount == 0
          ? null
          : fullTextDuration * playCount * 2,
      defaultScope: defaultScope,
      defaultPlaybackSpeed: defaults.playbackSpeed,
      defaultPause: intensivePauseChoiceFromSettings(defaults),
      onSelectionChanged: intensivePrefsRecorder(prefs, slot, defaults),
      onScopeChanged: (scope) {
        prefs.setListenAndRepeatScope(slot, scope);
        ref
            .read(learningProgressNotifierProvider.notifier)
            .saveShadowingSentenceIndex(audioItemId, null, isFreePlay: true);
      },
      onStartPractice: (playbackSpeed, pause, scope) async {
        if (scope == ListenAndRepeatScope.difficultOnly &&
            difficultIndices.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.difficultSentenceCount(0))),
          );
          return;
        }
        await pushPracticeAndWaitForTransition(
          context,
          AppRoutes.listenAndRepeatPlayer(collectionId, audioItemId),
          ref: ref,
          event: RatingPromptEvent.shadowingCompleted,
          extra: MediaLearningStartup(
            loadKey: '${audioItem.id}:listen-and-repeat:free-play',
            load: () async {
              final result = await ref
                  .read(listenAndRepeatControllerProvider.notifier)
                  .initialize(
                    mediaItem: audioItem,
                    allSentences: sentences,
                    isFreePlay: true,
                    scope: scope,
                    smartSpeed: smartSpeed,
                  );
              if (result != MediaLoadResult.ready) return result;
              ref
                  .read(learningSessionProvider.notifier)
                  .setCatchUp(
                    LearningStage.firstLearn,
                    SubStageType.listenAndRepeat,
                  );
              return result;
            },
            cancel: () => ref
                .read(listenAndRepeatControllerProvider.notifier)
                .cancelEntry(),
            showVideoLoading: audioItem.isVideo,
          ),
        );
      },
    );
  }

  /// 构建复述卡片副标题（总完成遍数）
  String? _buildRetellSubtitle(AppLocalizations l10n) {
    if (progress?.retellPassCount case final count? when count > 0) {
      return l10n.retellPassInfo(count);
    }
    return null;
  }

  /// 进入自由练习复述模式（弹 briefing sheet 选择段落时长）
  void _startFreePlayRetell(BuildContext context, WidgetRef ref) {
    _startFreePlayRetellAsync(context, ref);
  }

  /// 进入自由练习复述前先检查本地 ASR，避免步骤卡片直达绕过拦截。
  Future<void> _startFreePlayRetellAsync(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final allowed = await ensureSpeechReadyForSubStage(
      context,
      ref,
      SubStageType.retell,
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

    // 段落时长 default 按用户**当前**学习阶段算（review28 用户能驾驭长段），
    // 与 catchUpStage（始终 firstLearn，因为这是 firstLearn 子步骤的补练）解耦。
    // 可见词比例按 catchUpStage=firstLearn 算（补练 firstLearn 复述）。
    final progressForDefault = ref
        .read(learningProgressNotifierProvider)
        .progressMap[audioItemId];
    final stageForDefault =
        progressForDefault?.currentStage ?? LearningStage.firstLearn;
    // 按当前难句书签数实时重算难度，难度降低后速度/可见词比例随之调整
    final liveDifficulty = await ref
        .read(learningProgressNotifierProvider.notifier)
        .refreshDifficultyFromBookmarks(audioItemId, sentences.length);
    if (!context.mounted) return;
    // 自由练习复述属 firstLearn 补练,槽位 retell:firstLearn,与按计划共用偏好。
    final slot = stageSlotKey(
      StageSettingsSlots.retell,
      LearningStage.firstLearn,
    );
    final prefill = retellBriefingDefaults(
      ref,
      slot,
      smartSpeed: progressForDefault != null
          ? defaultPlaybackSpeedFor(liveDifficulty, LearningStage.firstLearn)
          : 1.0,
      smartRatio: KeywordRatio.forDifficultyAndStage(
        liveDifficulty,
        LearningStage.firstLearn,
      ),
      smartSeconds: retellDefaultSeconds(stageForDefault),
    );
    showRetellBriefingSheet(
      context: context,
      sentences: sentences,
      defaultSeconds: prefill.seconds,
      defaultKeywordRatio: progressForDefault != null ? prefill.ratio : null,
      defaultPlaybackSpeed: prefill.speed,
      repeatCount: prefill.settings.isManualMode
          ? 1
          : prefill.settings.repeatCount,
      defaultPause: prefill.pause,
      onSelectionChanged: retellPrefsRecorder(ref, slot, prefill.settings),
      onStartPractice:
          (targetDuration, pause, keywordRatio, playbackSpeed) async {
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
              loadKey: '${audioItem.id}:retell:free-play',
              isFreePlay: true,
              catchUpStage: LearningStage.firstLearn,
              catchUpSubStage: SubStageType.retell,
            );
          },
    );
  }
}
