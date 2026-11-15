// 学习计划表页面
//
// 展示音频的完整学习流程：首次学习（4步）和复习（7步）。
// 从 LearningProgressNotifier 读取真实进度数据，
// 步骤卡片支持三态：已完成、当前、未开始。
// 导航路径：合集详情 → 学习计划表 → 播放器
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../database/enums.dart';
import '../features/learning_plan/learning_flow_coordinator.dart';
import '../models/audio_item.dart';
import '../models/learning_progress.dart';
import '../models/media_learning_startup.dart';
import '../models/sentence.dart';
import '../providers/audio_engine/audio_engine_provider.dart';
import '../providers/audio_library_provider.dart';
import '../providers/audio_sentences_provider.dart';
import '../providers/collection_provider.dart';
import '../providers/learning_progress_provider.dart';
import '../providers/time_provider.dart';
import '../providers/learning_session/learning_session_provider.dart';
import '../models/stage_settings_overrides.dart';
import '../providers/blind_listen_prefs_provider.dart';
import '../providers/retell_prefs_provider.dart';
import '../providers/difficult_practice_prefs_provider.dart';
import '../providers/listening_practice/listening_practice_provider.dart';
import '../providers/new_user_guide_provider.dart';
import '../providers/settings_provider.dart';
import '../l10n/app_localizations.dart';
import '../router/app_router.dart';
import '../services/app_logger.dart';
import '../theme/app_theme.dart';
import '../models/difficult_practice_settings.dart';
import '../models/retell_settings.dart' show KeywordRatio;
import '../utils/blind_listen_duration_estimator.dart';
import '../utils/sub_stage_duration_estimator.dart';
import '../utils/paragraph_grouping.dart';
import '../utils/playback_speed_default.dart';
import '../utils/review_launch_planner.dart';
import '../utils/audio_item_actions.dart';
import '../utils/learning_practice_navigation.dart';
import '../utils/learning_start_planner.dart';
import '../widgets/blind_listen_paragraph_sheet.dart';
import '../widgets/common/app_popup_menu.dart';
import '../widgets/common/audio_app_bar_title.dart';
import '../widgets/retell/retell_briefing_sheet.dart';
import '../widgets/review/review_briefing_sheet.dart';
import '../widgets/speech_permission_dialog.dart';
import '../widgets/study/free_play_app_bar_button.dart';
import '../widgets/study/plan_progress_card.dart';
import '../widgets/study/plan_step_cards.dart';
import '../widgets/study/learning_plan_bottom_bar.dart';
import '../widgets/study/briefing_defaults.dart';
import '../widgets/study/first_study_section.dart';
import '../widgets/study/no_transcript_banner.dart';
import '../widgets/study/review_round_section.dart';
import '../widgets/guide_flow.dart';
import '../providers/listening_practice/bookmark_manager.dart';
import '../database/providers.dart';

const _durationDebugLogTag = 'MediaDuration';

/// 学习计划表页面
class LearningPlanScreen extends ConsumerStatefulWidget {
  /// 合集 ID（从独立音频路由进入时为 null）
  final String? collectionId;

  /// 音频项 ID
  final String audioItemId;

  /// 是否自动启动当前学习任务
  final bool autoStart;

  const LearningPlanScreen({
    super.key,
    this.collectionId,
    required this.audioItemId,
    this.autoStart = false,
  });

  @override
  ConsumerState<LearningPlanScreen> createState() => _LearningPlanScreenState();
}

class _LearningPlanScreenState extends ConsumerState<LearningPlanScreen> {
  /// autoStart 是否已触发
  bool _autoStartTriggered = false;

  /// loadAudio 的 Future，用于在读取 sentences 前确保音频加载完成
  Future<void>? _loadAudioFuture;

  /// 首次学习区域是否展开（首次学习阶段默认展开，进入复习阶段后默认折叠）
  bool? _isFirstLearnExpanded;

  /// 各复习轮次的展开状态（key 为复习大阶段）
  final Map<LearningStage, bool> _reviewRoundExpandedMap = {};

  // Guide step keys
  final _keyFreePlay = GlobalKey();
  final _keyStartLearning = GlobalKey();
  final _keyAddSubtitle = GlobalKey();
  final _keyPauseLearning = GlobalKey();

  /// 首次学习四个启动流程的编排器（流程正文不再写在本文件）。
  late final LearningFlowCoordinator _flows = LearningFlowCoordinator(
    ref: ref,
    audioItemId: widget.audioItemId,
    collectionId: widget.collectionId,
    ensureAudioLoaded: _ensureAudioLoaded,
    buildSkipCallback: _buildSkipCallback,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 确保学习进度记录存在
      ref
          .read(learningProgressNotifierProvider.notifier)
          .ensureProgress(widget.audioItemId);

      // 检查并加载音频数据
      final audioItem = ref
          .read(audioLibraryProvider.notifier)
          .getItemById(widget.audioItemId);
      if (audioItem == null) {
        AppLogger.log(
          _durationDebugLogTag,
          'event=plan_item_missing itemId=${widget.audioItemId}',
        );
        return;
      }
      AppLogger.log(
        _durationDebugLogTag,
        'event=plan_item_loaded trace=${audioItem.id} '
        'mediaType=${audioItem.mediaType.name} '
        'extension=${p.extension(audioItem.audioPath ?? '')} '
        'source=${audioItem.importSourceType?.name ?? 'unknown'} '
        'durationSeconds=${audioItem.totalDuration}',
      );

      // 始终调用 loadAudio：同一音频时只重新读取字幕，不重新加载音频文件
      _maybeLoadAudio(audioItem);

      // 监听字幕变化（上传/AI转录完成后重新加载字幕）。
      //
      // 字幕内容入库后，AI 转录完成不会再写 transcriptPath；学习计划页必须
      // 监听 transcriptSource / 统计字段等模型列，否则当前页内 LP 仍保留空句子，
      // 点击「开始学习」会在 sentences.isEmpty 分支静默返回。
      ref.listenManual(
        audioLibraryProvider.select(
          (s) =>
              s.audioItems.where((i) => i.id == widget.audioItemId).firstOrNull,
        ),
        (prev, next) {
          if (next == null) return;
          final transcriptChanged =
              prev?.transcriptPath != next.transcriptPath ||
              prev?.transcriptSource != next.transcriptSource ||
              prev?.transcriptLanguage != next.transcriptLanguage ||
              prev?.sentenceCount != next.sentenceCount ||
              prev?.wordCount != next.wordCount;
          if (transcriptChanged) {
            _maybeLoadAudio(next, forceTranscriptReload: true);
          }
        },
      );
    });
  }

  /// 加载音频到听力练习引擎；视频条目本期不接入播放引擎，直接跳过（仅保证页面不崩溃）。
  void _maybeLoadAudio(AudioItem item, {bool forceTranscriptReload = false}) {
    if (item.isVideo) return;
    _loadAudioFuture = ref
        .read(listeningPracticeProvider.notifier)
        .loadAudio(item, forceTranscriptReload: forceTranscriptReload);
  }

  /// 等待音频加载完成，返回 LP 状态。
  ///
  /// 如果加载后 audioItemId 不匹配（加载失败等），返回 null。
  Future<ListeningPracticeState?> _ensureAudioLoaded() async {
    await _loadAudioFuture;
    final lpState = ref.read(listeningPracticeProvider);
    if (lpState.currentAudioItem?.id != widget.audioItemId) return null;
    return lpState;
  }

  /// 构造"跳过当前子步骤"的回调。
  ///
  /// 首次学习的第一个盲听不可跳过（[LearningProgress.canSkipCurrentSubStage]
  /// 为 false），此时返回 null，简报弹窗据此隐藏「跳过」按钮。
  VoidCallback? _buildSkipCallback() {
    final progress = ref
        .read(learningProgressNotifierProvider)
        .progressMap[widget.audioItemId];
    if (!(progress?.canSkipCurrentSubStage ?? false)) return null;
    return () async {
      await ref
          .read(learningProgressNotifierProvider.notifier)
          .skipCurrentSubStage(widget.audioItemId);
    };
  }

  /// 打开「随心听」播放器（泛听/预热用途，不计学习进度）。
  ///
  /// 右上角随心听胶囊与「首次学习」预热卡共用此入口，保证目的地单一来源。
  void _openFreePlay(BuildContext context) {
    final audioItem = ref
        .read(audioLibraryProvider.notifier)
        .getItemById(widget.audioItemId);
    if (audioItem != null && audioItem.isVideo) {
      context.push(
        AppRoutes.mediaPlayer(widget.collectionId, widget.audioItemId),
        extra: audioItem,
      );
      return;
    }
    if (widget.collectionId != null) {
      context.push(
        AppRoutes.player(widget.collectionId!, widget.audioItemId),
        extra: audioItem,
      );
    } else {
      context.push(AppRoutes.audioPlayer(widget.audioItemId), extra: audioItem);
    }
  }

  /// 构建计划页顶栏「更多操作」菜单（随心听按钮右侧）。
  ///
  /// 承载对当前音频的重要操作：管理字幕、编辑字幕、导出音频、导出 PDF、重置进度。
  /// 与音频列表项菜单同源（复用 [showManageSubtitlesSheet]/[exportAudioItem]）。
  /// 社区音频隐藏字幕/导出写操作，仅在有字幕时保留导出 PDF；无可用项时返回 null。
  Widget? _buildPlanMenu(
    BuildContext context,
    AppLocalizations l10n,
    AudioItem audioItem,
    LearningProgress? progress,
  ) {
    final isCommunity = audioItem.remoteAudioId != null;
    final hasTranscript = audioItem.hasTranscript;
    final hasProgress = progress?.isStarted ?? false;

    final items = <PopupMenuEntry<String>>[
      if (!isCommunity)
        appPopupMenuItem(
          context,
          value: 'manageSubtitles',
          icon: const Icon(Icons.subtitles_outlined, size: 20),
          label: l10n.manageSubtitles,
        ),
      if (!isCommunity && hasTranscript)
        appPopupMenuItem(
          context,
          value: 'editSubtitles',
          icon: const Icon(Icons.edit_note, size: 20),
          label: l10n.editSubtitles,
        ),
      if (!isCommunity)
        appPopupMenuItem(
          context,
          value: 'export',
          icon: const Icon(Icons.ios_share, size: 20),
          label: audioItem.isVideo ? l10n.exportVideo : l10n.exportAudio,
        ),
      if (hasTranscript)
        appPopupMenuItem(
          context,
          value: 'exportPdf',
          icon: const Icon(Icons.picture_as_pdf_outlined, size: 20),
          label: l10n.exportPdf,
        ),
      // 与音频列表菜单保持一致：仅在已有实际学习进度时提供危险的重置操作。
      if (hasProgress)
        appPopupMenuItem(
          context,
          value: 'resetProgress',
          icon: Icon(
            Icons.restart_alt,
            size: 20,
            color: Theme.of(context).colorScheme.error,
          ),
          label: l10n.resetLearningProgress,
          destructive: true,
        ),
    ];

    if (items.isEmpty) return null;

    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.s),
      child: PopupMenuButton<String>(
        key: const Key('learning_plan_more_menu'),
        tooltip: MaterialLocalizations.of(context).showMenuTooltip,
        icon: const Icon(Icons.more_horiz),
        itemBuilder: (_) => items,
        onSelected: (value) {
          switch (value) {
            case 'manageSubtitles':
              showManageSubtitlesSheet(context, ref, audioItem);
            case 'editSubtitles':
              context.push(
                AppRoutes.subtitleEditor(audioItem.id),
                extra: audioItem,
              );
            case 'export':
              exportAudioItem(context, ref, audioItem);
            case 'exportPdf':
              AppRoutes.pushNested(
                context,
                AppRoutes.pdfPreviewSegment,
                extra: audioItem,
              );
            case 'resetProgress':
              _showResetProgressDialog(context, l10n, audioItem);
          }
        },
      ),
    );
  }

  /// 确认后清除当前音频的学习进度，并保留音频与字幕内容。
  Future<void> _showResetProgressDialog(
    BuildContext context,
    AppLocalizations l10n,
    AudioItem audioItem,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.resetLearningProgressConfirmTitle),
        content: Text(l10n.resetLearningProgressConfirmMessage(audioItem.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await ref
        .read(learningProgressNotifierProvider.notifier)
        .resetProgress(audioItem.id);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.resetLearningProgressDone)));
    }
  }

  /// 处理"开始学习/继续学习"按钮点击。
  ///
  /// 首帧进入计划页时，进度可能仍在 [ensureProgress] 异步创建中；此时
  /// 必须等待并读取真实进度，不能把 null 误判为盲听入口。
  Future<void> _handleStartLearning(
    BuildContext context,
    LearningProgress? progress,
  ) async {
    final effectiveProgress =
        progress ??
        await ref
            .read(learningProgressNotifierProvider.notifier)
            .getLatestOrEnsureProgress(widget.audioItemId);
    if (!context.mounted) return;

    final action = planLearningStart(
      progress: effectiveProgress,
      now: ref.read(nowProvider)(),
    );
    switch (action) {
      case LearningStartAction.blocked:
        return;
      case LearningStartAction.reviewSubStage:
        _startReviewSubStage(context, effectiveProgress);
      case LearningStartAction.blindListen:
        _flows.startBlindListen(context, effectiveProgress);
      case LearningStartAction.intensiveListen:
        _flows.startIntensiveListen(context);
      case LearningStartAction.listenAndRepeat:
        _flows.startListenAndRepeat(context);
      case LearningStartAction.retell:
        _flows.startRetelling(context);
      case LearningStartAction.freePlay:
        _openFreePlay(context);
    }
  }

  /// 无字幕时保留学习入口的可点击反馈，明确告知用户开始学习的前置条件。
  void _showMissingTranscriptSnackBar(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context)!.noTranscriptWarning),
      ),
    );
  }

  /// 复习阶段：按 subStage 分发到真实页面。
  ///
  /// 盲听和段落复述自带段落选择弹窗，无需再展示复习简报；
  /// 其余子阶段先展示复习简报弹窗。
  Future<void> _startReviewSubStage(
    BuildContext context,
    LearningProgress progress,
  ) async {
    final subStage = progress.currentSubStage;
    final launch = planReviewLaunch(subStage, autoAdvance: false);

    // 段落复述自带时长选择弹窗；盲听自带段落选择弹窗（阶段名与预估时长就在弹窗上）。
    if (launch == ReviewLaunch.retellParagraph) {
      _startReviewRetell(context, isSummary: false);
      return;
    }
    if (launch == ReviewLaunch.blindListen) {
      _startReviewBlindListen(context, stage: progress.currentStage);
      return;
    }

    // 按当前难句书签数实时重算难度，难度降低后速度随之回升
    final lpState = await _ensureAudioLoaded();
    if (!context.mounted) return;
    final liveDifficulty = await ref
        .read(learningProgressNotifierProvider.notifier)
        .refreshDifficultyFromBookmarks(
          widget.audioItemId,
          lpState?.sentences.length ?? 0,
        );
    if (!context.mounted) return;

    final reviewStage = progress.currentStage;
    final smartSpeed = defaultPlaybackSpeedFor(liveDifficulty, reviewStage);

    // 难句补练:按槽位 typed 偏好(轮次独立)。
    if (subStage == SubStageType.reviewDifficultPractice) {
      final slot = stageSlotKey(
        StageSettingsSlots.reviewDifficultPractice,
        reviewStage,
      );
      final dp = ref.read(difficultPracticePrefsProvider.notifier);
      final defaults = dp.resolve(slot, smartSpeed: smartSpeed);
      final estimatedDuration = _estimateReviewDuration(
        subStage,
        difficultBlindListenRepeatCount: defaults.isManualMode
            ? 1
            : defaults.blindListenRepeatCount,
        difficultShadowReadingRepeatCount: defaults.isManualMode
            ? 1
            : defaults.shadowReadingRepeatCount,
      );
      showReviewBriefingSheet(
        context: context,
        stage: reviewStage,
        subStage: subStage,
        estimatedDuration: estimatedDuration,
        defaultPlaybackSpeed: defaults.playbackSpeed,
        defaultPause: difficultPauseChoiceFromSettings(defaults),
        onSelectionChanged: difficultPrefsRecorder(ref, slot, defaults),
        onStartPractice: (playbackSpeed, pause) {
          final settings = ref
              .read(difficultPracticePrefsProvider.notifier)
              .resolve(slot, smartSpeed: smartSpeed);
          _startReviewDifficultPractice(
            context,
            settings: settings,
            stage: reviewStage,
          );
        },
        onSkip: _buildSkipCallback(),
      );
      return;
    }

    // 全文复述(reviewRetellSummary):按槽位 typed 偏好。
    final slot = stageSlotKey(StageSettingsSlots.retell, reviewStage);
    final rp = ref.read(retellPrefsProvider.notifier);
    final smartRatio = KeywordRatio.forDifficultyAndStage(
      liveDifficulty,
      reviewStage,
    );
    final defaults = rp.resolve(
      slot,
      smartSpeed: smartSpeed,
      smartRatio: smartRatio,
    );
    final estimatedDuration = _estimateReviewDuration(
      subStage,
      retellRepeatCount: defaults.isManualMode ? 1 : defaults.repeatCount,
    );
    showReviewBriefingSheet(
      context: context,
      stage: reviewStage,
      subStage: subStage,
      estimatedDuration: estimatedDuration,
      defaultPlaybackSpeed: defaults.playbackSpeed,
      defaultPause: retellPauseChoiceFromSettings(defaults),
      onSelectionChanged: retellPauseSpeedRecorder(ref, slot, defaults),
      onStartPractice: (playbackSpeed, pause) {
        _startReviewRetell(context, isSummary: true);
      },
      onSkip: _buildSkipCallback(),
    );
  }

  /// 预估复习子步骤时长（口径见 `estimateSubStageDuration`）
  Duration? _estimateReviewDuration(
    SubStageType subStage, {
    int difficultBlindListenRepeatCount = 1,
    int difficultShadowReadingRepeatCount = 3,
    int retellRepeatCount = 1,
  }) {
    return estimateSubStageDuration(
      subStage: subStage,
      sentences: ref.read(listeningPracticeProvider).sentences,
      fullAudioDuration: ref.read(audioEngineProvider).totalDuration,
      skipSilenceEnabled: ref.read(appSettingsProvider).skipSilenceEnabled,
      difficultBlindListenRepeatCount: difficultBlindListenRepeatCount,
      difficultShadowReadingRepeatCount: difficultShadowReadingRepeatCount,
      retellRepeatCount: retellRepeatCount,
    );
  }

  /// 复习盲听：弹段落选择弹窗后进入段落播放
  ///
  /// [stage] 当前复习阶段，用于在弹窗上显示阶段名和预估时长。
  Future<void> _startReviewBlindListen(
    BuildContext context, {
    required LearningStage stage,
  }) async {
    final audioItem = ref
        .read(audioLibraryProvider.notifier)
        .getItemById(widget.audioItemId);
    if (audioItem == null) return;
    final lpState = audioItem.isVideo ? null : await _ensureAudioLoaded();
    if (!context.mounted) return;
    final sentences = audioItem.isVideo
        ? await ref.read(audioSentencesProvider(widget.audioItemId).future)
        : lpState?.sentences ?? const <Sentence>[];
    if (!context.mounted) return;
    if (sentences.isEmpty) return;

    final l10n = AppLocalizations.of(context)!;
    final estimatedDuration = estimateBlindListenSessionDuration(
      sentences: sentences,
      fullAudioDuration: ref.read(audioEngineProvider).totalDuration,
      skipSilenceEnabled: ref.read(appSettingsProvider).skipSilenceEnabled,
    );
    final estimatedText = estimatedDuration != null
        ? formatEstimatedDuration(l10n, estimatedDuration)
        : null;

    final progressForSpeed = ref
        .read(learningProgressNotifierProvider)
        .progressMap[widget.audioItemId];
    // 按当前难句书签数实时重算难度，难度降低后速度随之回升
    final liveDifficulty = await ref
        .read(learningProgressNotifierProvider.notifier)
        .refreshDifficultyFromBookmarks(widget.audioItemId, sentences.length);
    if (!context.mounted) return;
    final skip = _buildSkipCallback();
    final smartSpeed = progressForSpeed != null
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
      stageLabel: reviewStageLabel(l10n, stage),
      estimatedDurationText: estimatedText,
      defaultPlaybackSpeed: defaults.playbackSpeed,
      defaultSeconds: blindSeconds,
      defaultPause: blindPauseChoiceFromSettings(defaults),
      onSelectionChanged: blindPrefsRecorder(ref, slot, defaults, blindSeconds),
      skipLabel: skip != null ? l10n.retellSkip : null,
      onSkip: skip,
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
          collectionId: widget.collectionId,
          paragraphs: paragraphs,
          settings: settings,
          stage: stage,
          loadKey: '${audioItem.id}:blind-listen:${stage.key}:planned',
        );
      },
    );
  }

  /// 复习难句补练：进入 ReviewDifficultPracticeScreen
  ///
  /// 先检查书签数量，无难句时自动完成并跳到下一复述子阶段。
  Future<void> _startReviewDifficultPractice(
    BuildContext context, {
    DifficultPracticeSettings settings = const DifficultPracticeSettings(),
    LearningStage? stage,
  }) async {
    final allowed = await ensureSpeechReadyForSubStage(
      context,
      ref,
      SubStageType.reviewDifficultPractice,
    );
    if (!allowed || !context.mounted) return;

    final audioItem = ref
        .read(audioLibraryProvider.notifier)
        .getItemById(widget.audioItemId);
    if (audioItem == null) return;
    final lpState = audioItem.isVideo ? null : await _ensureAudioLoaded();
    if (!context.mounted) return;
    final sentences = audioItem.isVideo
        ? await ref.read(audioSentencesProvider(widget.audioItemId).future)
        : lpState?.sentences;
    if (!context.mounted || sentences == null) return;
    final l10n = AppLocalizations.of(context)!;

    if (sentences.isEmpty) {
      // 无字幕 → 跳过
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.reviewDifficultPracticeNone)),
        );
      }
      return;
    }

    // 检查书签数量（难句数）
    final bookmarkDao = ref.read(bookmarkDaoProvider);
    final bookmarks = await BookmarkManager.loadBookmarks(
      widget.audioItemId,
      dao: bookmarkDao,
    );
    if (!context.mounted) return;

    if (bookmarks.isEmpty) {
      // 无难句 → 自动完成补练，推进到下一子阶段
      await ref
          .read(learningProgressNotifierProvider.notifier)
          .completeCurrentSubStage(widget.audioItemId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.reviewDifficultPracticeNone)));
      // 推进后根据新位置自动进入下一子步骤（复述 / v2 review0 的全文盲听）
      _navigateToNextReviewSubStageFromPlan(context);
      return;
    }

    final route = AppRoutes.reviewDifficultPractice(
      widget.collectionId,
      widget.audioItemId,
    );
    context.push(
      route,
      extra: MediaLearningStartup(
        loadKey:
            '${audioItem.id}:review-difficult:${stage?.key ?? 'current'}:planned',
        showVideoLoading: audioItem.isVideo,
        load: () => ref
            .read(learningSessionProvider.notifier)
            .enterReviewDifficultPracticeMode(
              audioItem,
              sentences,
              settings: settings,
              stage: stage,
            ),
        cancel: () => ref
            .read(learningSessionProvider.notifier)
            .cancelReviewDifficultPracticeEntry(),
      ),
    );
  }

  /// 自动完成难句补练后，按新的 `currentSubStage` 自动进入下一个子步骤。
  ///
  /// 处理：
  /// - v1 review0：reviewRetellParagraph → 段落复述
  /// - v2 review0：blindListen → 复习盲听
  /// - 中间轮 review1~14：blindListen / reviewRetellParagraph
  /// - 末轮 review28：blindListen / reviewRetellSummary
  /// - 跨阶段推进到 completed / firstLearn 等其它情况：不导航，回到计划页。
  void _navigateToNextReviewSubStageFromPlan(BuildContext context) {
    final progress = ref
        .read(learningProgressNotifierProvider)
        .progressMap[widget.audioItemId];
    if (progress == null) return;
    if (!progress.isInReviewStage) return;

    switch (planReviewLaunch(progress.currentSubStage, autoAdvance: true)) {
      case ReviewLaunch.blindListen:
        _startReviewBlindListen(context, stage: progress.currentStage);
      case ReviewLaunch.retellParagraph:
        _startReviewRetell(context, isSummary: false);
      case ReviewLaunch.retellSummary:
        _startReviewRetell(context, isSummary: true);
      case ReviewLaunch.briefing:
      case ReviewLaunch.none:
        // 推进后罕见落到难句补练等情况，回到计划页让用户重新选择
        break;
    }
  }

  /// 复习复述：复用 RetellPlayerScreen
  ///
  /// [isSummary] 为 true 时全文作为单个段落（reviewRetellSummary）
  Future<void> _startReviewRetell(
    BuildContext context, {
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
        .getItemById(widget.audioItemId);
    if (audioItem == null) return;
    final lpState = audioItem.isVideo ? null : await _ensureAudioLoaded();
    if (!context.mounted) return;
    final sentences = audioItem.isVideo
        ? await ref.read(audioSentencesProvider(widget.audioItemId).future)
        : lpState?.sentences;
    if (!context.mounted || sentences == null) return;

    if (sentences.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.intensiveListenNoSubtitle,
            ),
          ),
        );
      }
      return;
    }

    if (isSummary) {
      // reviewRetellSummary：全文作为单个段落；停顿/速度已由复习简报落入偏好,
      // enterRetellMode 内部按槽位 resolve 出完整设置。
      await openRetellPractice(
        context: context,
        ref: ref,
        audioItem: audioItem,
        collectionId: widget.collectionId,
        paragraphs: [sentences],
        loadKey: '${audioItem.id}:retell-summary:planned',
      );
      return;
    }

    // reviewRetellParagraph：弹出简报面板让用户选择段落时长
    final progress = ref
        .read(learningProgressNotifierProvider)
        .progressMap[widget.audioItemId];
    final currentStage = progress?.currentStage;

    // 复习阶段显示阶段名；预估时长由 briefing sheet 内部按真实公式动态计算
    final l10n = AppLocalizations.of(context)!;
    final isReview =
        currentStage != null && currentStage != LearningStage.firstLearn;

    final effectiveStage = currentStage ?? LearningStage.firstLearn;
    // 按当前难句书签数实时重算难度，难度降低后速度/可见词比例随之调整
    final liveDifficulty = await ref
        .read(learningProgressNotifierProvider.notifier)
        .refreshDifficultyFromBookmarks(widget.audioItemId, sentences.length);
    if (!context.mounted) return;
    final smartRatio = KeywordRatio.forDifficultyAndStage(
      liveDifficulty,
      effectiveStage,
    );
    final slot = stageSlotKey(StageSettingsSlots.retell, effectiveStage);
    final prefill = retellBriefingDefaults(
      ref,
      slot,
      smartSpeed: progress != null
          ? defaultPlaybackSpeedFor(liveDifficulty, effectiveStage)
          : 1.0,
      smartRatio: smartRatio,
      smartSeconds: retellDefaultSeconds(currentStage),
    );
    showRetellBriefingSheet(
      context: context,
      sentences: sentences,
      defaultSeconds: prefill.seconds,
      stageLabel: isReview ? reviewStageLabel(l10n, currentStage) : null,
      defaultKeywordRatio: progress != null ? prefill.ratio : null,
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
              collectionId: widget.collectionId,
              paragraphs: paragraphs,
              loadKey: '${audioItem.id}:retell-paragraph:planned',
            );
          },
      // 按计划学习路径才显示「跳过」按钮；自由练习路径无此回调
      onSkip: () async {
        await ref
            .read(learningProgressNotifierProvider.notifier)
            .skipCurrentSubStage(widget.audioItemId);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final audioItem = ref.watch(
      audioLibraryProvider.select(
        (s) =>
            s.audioItems.where((i) => i.id == widget.audioItemId).firstOrNull,
      ),
    );

    // 监听学习进度
    final progress = ref.watch(
      learningProgressNotifierProvider.select(
        (s) => s.progressMap[widget.audioItemId],
      ),
    );
    final now = ref.watch(nowProvider)();

    // audioItem 找不到时显示错误页面
    if (audioItem == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(l10n.audioFileNotFound)),
      );
    }

    // autoStart：正常渲染计划页，同时自动触发 _handleStartLearning（弹 briefing sheet）
    if (widget.autoStart && !_autoStartTriggered) {
      _autoStartTriggered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _handleStartLearning(context, progress);
      });
    }

    final reviewStages = _buildReviewStages(l10n);

    // 当前音频所属的所有合集名（按合集列表顺序），用于 AppBar 副标题
    final collectionNames = ref.watch(
      collectionListProvider.select((s) {
        final ids = s.audioToCollectionsMap[widget.audioItemId] ?? const [];
        if (ids.isEmpty) return const <String>[];
        final idSet = ids.toSet();
        return s.collections
            .where((c) => idSet.contains(c.id))
            .map((c) => c.name)
            .toList(growable: false);
      }),
    );

    final hasTranscript = audioItem.hasTranscript;
    final isLockedReview = progress?.isReviewLockedAt(now) ?? false;
    final startLearningAction = !isLockedReview
        ? hasTranscript
              ? () => _handleStartLearning(context, progress)
              : () => _showMissingTranscriptSnackBar(context)
        : null;

    final stepFreePlay = GuideStep(
      key: _keyFreePlay,
      title: l10n.guidePlanFreePlayTitle,
      description: l10n.guidePlanFreePlayDescription,
    );
    final stepStartLearning = GuideStep(
      key: _keyStartLearning,
      title: l10n.guidePlanStartLearningTitle,
      description: l10n.guidePlanStartLearningDescription,
    );
    final stepAddSubtitle = GuideStep(
      key: _keyAddSubtitle,
      title: l10n.guidePlanAddSubtitleTitle,
      description: l10n.guidePlanAddSubtitleDescription,
    );
    final stepPauseLearning = GuideStep(
      key: _keyPauseLearning,
      title: l10n.guidePlanPauseLearningTitle,
      description: l10n.guidePlanPauseLearningDescription,
    );

    // 暂停学习按钮仅在已开始学习且当前未暂停时才会渲染，引导也只在此时
    // 触发；和「自由练习 / 按计划学习」flow 隔离，让用户开始学习后再看到。
    final showPauseLearningGuide =
        hasTranscript &&
        (progress?.isStarted ?? false) &&
        !(progress?.isPaused ?? false);

    final flows = <GuideFlow>[
      GuideFlow(
        flowId: GuideFlowIds.learningPlanWithTranscript,
        shouldRun: hasTranscript,
        steps: [stepFreePlay, stepStartLearning],
      ),
      GuideFlow(
        flowId: GuideFlowIds.learningPlanNoTranscript,
        shouldRun: !hasTranscript,
        steps: [stepAddSubtitle],
      ),
      GuideFlow(
        flowId: GuideFlowIds.learningPlanPauseLearning,
        shouldRun: showPauseLearningGuide,
        steps: [stepPauseLearning],
      ),
    ];

    return GuideFlowSequenceHost(
      flows: flows,
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: AudioAppBarTitle(
            audioName: audioItem.name,
            collectionNames: collectionNames,
          ),
          actions: [
            GuideTarget(
              step: stepFreePlay,
              child: Padding(
                padding: const EdgeInsets.only(right: AppSpacing.s),
                child: FreePlayAppBarButton(
                  label: l10n.freePlay,
                  onPressed: () => _openFreePlay(context),
                ),
              ),
            ),
            ?_buildPlanMenu(context, l10n, audioItem, progress),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.m),
                children: [
                  PlanProgressCard(
                    l10n: l10n,
                    progress: progress,
                    audioItem: audioItem,
                    now: now,
                  ),
                  if (!hasTranscript) ...[
                    const SizedBox(height: AppSpacing.s),
                    NoTranscriptBanner(
                      l10n: l10n,
                      addSubtitleStep: stepAddSubtitle,
                      onManageSubtitles: () =>
                          showManageSubtitlesSheet(context, ref, audioItem),
                    ),
                  ],
                  // 听前预热卡：未开始本音频且有字幕时显示，引导用户先随心听
                  // 熟悉内容。放在「首次学习」之上，作为整个学习流程的前置预热；
                  // 用户开始学习后 isStarted 变 true，卡片自动消失（按音频维度
                  // 一次性，无需新增持久化）。
                  if ((progress == null || !progress.isStarted) &&
                      hasTranscript) ...[
                    const SizedBox(height: AppSpacing.s),
                    PlanWarmUpCard(
                      l10n: l10n,
                      onTap: () => _openFreePlay(context),
                    ),
                    const SizedBox(height: AppSpacing.s),
                  ] else
                    const SizedBox(height: AppSpacing.l),
                  FirstStudySection(
                    l10n: l10n,
                    progress: progress,
                    collectionId: widget.collectionId,
                    audioItemId: widget.audioItemId,
                    isExpanded: _isFirstLearnExpanded ??=
                        progress?.isCurrentStage(LearningStage.firstLearn) ??
                        true,
                    onToggle: () => setState(
                      () => _isFirstLearnExpanded =
                          !(_isFirstLearnExpanded ?? true),
                    ),
                    onStartCurrentStage: startLearningAction,
                  ),
                  const SizedBox(height: AppSpacing.m),
                  ...List.generate(reviewStages.length, (index) {
                    final review = reviewStages[index];
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: index == reviewStages.length - 1
                            ? 0
                            : AppSpacing.m,
                      ),
                      child: ReviewRoundSection(
                        l10n: l10n,
                        progress: progress,
                        review: review,
                        now: now,
                        collectionId: widget.collectionId,
                        audioItemId: widget.audioItemId,
                        isExpanded: _isReviewRoundExpanded(
                          review.stage,
                          progress,
                        ),
                        onToggle: () =>
                            _toggleReviewRoundExpanded(review.stage),
                        onStartCurrentStage: startLearningAction,
                      ),
                    );
                  }),
                ],
              ),
            ),
            LearningPlanBottomBar(
              l10n: l10n,
              progress: progress,
              audioItemId: widget.audioItemId,
              audioItemName: audioItem.name,
              startLearningStep: hasTranscript ? stepStartLearning : null,
              pauseLearningStep: showPauseLearningGuide
                  ? stepPauseLearning
                  : null,
              onPressed: startLearningAction,
            ),
          ],
        ),
      ),
    );
  }

  /// 构建复习阶段列表（review0 ~ review28，共 7 个）
  List<ReviewStageData> _buildReviewStages(AppLocalizations l10n) {
    return [
      ReviewStageData(name: l10n.reviewRound0, stage: LearningStage.review0),
      ReviewStageData(name: l10n.reviewRound1, stage: LearningStage.review1),
      ReviewStageData(name: l10n.reviewRound2, stage: LearningStage.review2),
      ReviewStageData(name: l10n.reviewRound4, stage: LearningStage.review4),
      ReviewStageData(name: l10n.reviewRound7, stage: LearningStage.review7),
      ReviewStageData(name: l10n.reviewRound14, stage: LearningStage.review14),
      ReviewStageData(name: l10n.reviewRound28, stage: LearningStage.review28),
    ];
  }

  /// 读取复习轮次展开态（仅首次按默认规则初始化）
  ///
  /// 默认规则：
  /// - 已完成轮次：折叠
  /// - 当前进行中轮次：展开
  /// - 未来轮次：折叠
  bool _isReviewRoundExpanded(LearningStage stage, LearningProgress? progress) {
    return _reviewRoundExpandedMap.putIfAbsent(
      stage,
      () => progress?.isCurrentStage(stage) ?? false,
    );
  }

  /// 切换单个复习轮次的展开态
  void _toggleReviewRoundExpanded(LearningStage stage) {
    setState(() {
      _reviewRoundExpandedMap[stage] =
          !(_reviewRoundExpandedMap[stage] ?? false);
    });
  }
}
