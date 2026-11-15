/// 学习计划页「首次学习」四个启动流程的编排。
///
/// 每个流程做的事一样：取音频与字幕 → 按槽位解析偏好 → 估时 → 弹简报 →
/// 进入对应练习页（无字幕/权限不足/跳过时按同一套规则收尾）。页面只负责注入
/// 上下文与两个回调（校准音频、跳过能力），不再自己持有这些流程。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/enums.dart';
import '../../features/rating_prompt/domain/rating_prompt_policy.dart';
import '../../l10n/app_localizations.dart';
import '../../models/learning_progress.dart';
import '../../models/media_learning_startup.dart';
import '../../models/retell_settings.dart';
import '../../models/stage_settings_overrides.dart';
import '../../providers/audio_engine/audio_engine_provider.dart';
import '../../providers/audio_library_provider.dart';
import '../../providers/audio_sentences_provider.dart';
import '../../providers/blind_listen_prefs_provider.dart';
import '../../providers/intensive_listen_prefs_provider.dart';
import '../../providers/learning_progress_provider.dart';
import '../../providers/learning_session/sentence_playback_engine.dart';
import '../../providers/learning_session/learning_session_provider.dart';
import '../../providers/listen_and_repeat/listen_and_repeat_controller.dart';
import '../../providers/listening_practice/bookmark_manager.dart';
import '../../providers/listening_practice/listening_practice_provider.dart';
import '../../providers/settings_provider.dart';
import '../../router/app_router.dart';
import '../../utils/blind_listen_duration_estimator.dart';
import '../../utils/learning_duration_estimator.dart';
import '../../utils/learning_practice_navigation.dart';
import '../../utils/paragraph_grouping.dart';
import '../../utils/playback_speed_default.dart';
import '../../widgets/blind_listen_paragraph_sheet.dart';
import '../../widgets/intensive_listen/intensive_listen_briefing_sheet.dart';
import '../../widgets/listen_and_repeat/listen_and_repeat_briefing_sheet.dart';
import '../../widgets/retell/retell_briefing_sheet.dart';
import '../../widgets/review/review_briefing_sheet.dart';
import '../../widgets/speech_permission_dialog.dart';
import '../../widgets/study/briefing_defaults.dart';
import '../../database/providers.dart';

/// 首次学习各流程的编排器。
///
/// 依赖由页面注入：ref 用来读 provider，[ensureAudioLoaded] 校准字幕与播放器，
/// [buildSkipCallback] 给出当前子步骤能否跳过。这样四个流程的正文不再依赖
/// 页面私有状态，页面侧只剩一行转发。
class LearningFlowCoordinator {
  LearningFlowCoordinator({
    required this.ref,
    required this.audioItemId,
    required this.collectionId,
    required this.ensureAudioLoaded,
    required this.buildSkipCallback,
  });

  final WidgetRef ref;
  final String audioItemId;
  final String? collectionId;

  /// 校准字幕与播放器状态（由页面提供）。
  final Future<ListeningPracticeState?> Function() ensureAudioLoaded;

  /// 当前子步骤是否可跳过（由页面提供，不可跳过时返回 null）。
  final VoidCallback? Function() buildSkipCallback;

  /// 进入全文盲听
  ///
  /// 先弹简报弹窗，点"开始练习"后等待音频加载，
  /// 有字幕时再弹段落选择弹窗，无字幕时直接进入极简播放。
  Future<void> startBlindListen(
    BuildContext context,
    LearningProgress? progress,
  ) async {
    final audioItem = ref
        .read(audioLibraryProvider.notifier)
        .getItemById(audioItemId);
    if (audioItem == null) return;
    // 视频字幕直接从数据库读取，避免把视频送入原音频播放链路。
    final lpState = audioItem.isVideo ? null : await ensureAudioLoaded();
    if (!context.mounted) return;
    final sentences = audioItem.isVideo
        ? await ref.read(audioSentencesProvider(audioItemId).future)
        : lpState?.sentences ?? const [];

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

    // 首次学习的第一个盲听不可跳过，_buildSkipCallback 在此返回 null（无跳过按钮）
    final skip = buildSkipCallback();
    // 全文盲听属于首次学习步骤，按 firstLearn 阶段算默认速度
    const stage = LearningStage.firstLearn;
    final smartSpeed = progress != null
        ? defaultPlaybackSpeedFor(liveDifficulty, LearningStage.firstLearn)
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
          collectionId: collectionId,
          paragraphs: paragraphs,
          settings: settings,
          stage: stage,
          loadKey: '${audioItem.id}:blind-listen:planned',
        );
      },
    );
  }

  /// 进入逐句精听
  Future<void> startIntensiveListen(BuildContext context) async {
    final audioItem = ref
        .read(audioLibraryProvider.notifier)
        .getItemById(audioItemId);
    if (audioItem == null) return;
    final sentences = audioItem.isVideo
        ? await ref.read(audioSentencesProvider(audioItemId).future)
        : (await ensureAudioLoaded())?.sentences;
    if (!context.mounted || sentences == null) return;
    final l10n = AppLocalizations.of(context)!;

    // 无字幕则提示用户上传
    if (sentences.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.intensiveListenNoSubtitle),
          content: Text(l10n.intensiveListenNoSubtitleMessage),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.ok),
            ),
          ],
        ),
      );
      return;
    }

    final totalSentenceDuration = sentences.fold<Duration>(
      Duration.zero,
      (sum, s) => sum + s.duration,
    );

    // 单一真相源:逐句精听仅在首学,槽位 intensiveListen:firstLearn。
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
      // 改完即记(与 🔧 面板一致):无论是否「开始练习」、即使关闭弹窗都已持久化。
      onSelectionChanged: intensivePrefsRecorder(prefs, slot, defaults),
      onStartPractice: (playbackSpeed, pause) async {
        final session = ref.read(learningSessionProvider.notifier);
        final resolved = prefs.resolve(slot, smartSpeed: 1.0);
        if (!context.mounted) return;
        context.push(
          AppRoutes.intensiveListenPlayer(collectionId, audioItemId),
          extra: MediaLearningStartup(
            loadKey: '${audioItem.id}:planned',
            load: () => session.enterIntensiveListenMode(
              audioItem,
              sentences,
              settings: resolved,
              settingsSlot: slot,
            ),
            cancel: session.cancelIntensiveListenEntry,
            showVideoLoading: audioItem.isVideo,
          ),
        );
      },
      onSkip: buildSkipCallback(),
    );
  }

  /// 进入难句跟读
  Future<void> startListenAndRepeat(BuildContext context) async {
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
        : (await ensureAudioLoaded())?.sentences;
    if (!context.mounted || sentences == null) return;
    final l10n = AppLocalizations.of(context)!;

    if (sentences.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.intensiveListenNoSubtitle),
          content: Text(l10n.intensiveListenNoSubtitleMessage),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.ok),
            ),
          ],
        ),
      );
      return;
    }

    final bookmarkDao = ref.read(bookmarkDaoProvider);
    final difficultIndices = await BookmarkManager.loadBookmarks(
      audioItemId,
      dao: bookmarkDao,
    );
    if (!context.mounted) return;

    final progress = ref
        .read(learningProgressNotifierProvider)
        .progressMap[audioItemId];
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
    const stage = LearningStage.firstLearn;
    final smartSpeed = progress != null
        ? defaultPlaybackSpeedFor(liveDifficulty, LearningStage.firstLearn)
        : 1.0;
    // 难句跟读与逐句精听共用 IntensiveListenPrefs store,槽位 listenAndRepeat:firstLearn。
    final slot = stageSlotKey(StageSettingsSlots.listenAndRepeat, stage);
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
            .saveShadowingSentenceIndex(audioItemId, null, isFreePlay: false);
      },
      onStartPractice: (playbackSpeed, pause, scope) async {
        if (scope == ListenAndRepeatScope.difficultOnly &&
            difficultIndices.isEmpty) {
          await ref
              .read(learningProgressNotifierProvider.notifier)
              .completeCurrentSubStage(audioItemId);
          if (!context.mounted) return;
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
            loadKey: '${audioItem.id}:listen-and-repeat:planned',
            showVideoLoading: audioItem.isVideo,
            load: () => ref
                .read(listenAndRepeatControllerProvider.notifier)
                .initialize(
                  mediaItem: audioItem,
                  allSentences: sentences,
                  isFreePlay: false,
                  scope: scope,
                  smartSpeed: smartSpeed,
                  stage: stage,
                ),
            cancel: () => ref
                .read(listenAndRepeatControllerProvider.notifier)
                .cancelEntry(),
          ),
        );
      },
      onSkip: buildSkipCallback(),
    );
  }

  /// 进入段落复述
  Future<void> startRetelling(BuildContext context) async {
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
    final lpState = audioItem.isVideo ? null : await ensureAudioLoaded();
    if (!context.mounted) return;
    final sentences = audioItem.isVideo
        ? await ref.read(audioSentencesProvider(audioItemId).future)
        : lpState?.sentences;
    if (!context.mounted || sentences == null) return;
    final l10n = AppLocalizations.of(context)!;

    // 无字幕则提示
    if (sentences.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.intensiveListenNoSubtitle),
          content: Text(l10n.intensiveListenNoSubtitleMessage),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.ok),
            ),
          ],
        ),
      );
      return;
    }

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
    final hasProgress = progressForDefault != null;
    final smartRatio = KeywordRatio.forDifficultyAndStage(
      liveDifficulty,
      stageForDefault,
    );
    final slot = stageSlotKey(StageSettingsSlots.retell, stageForDefault);
    final prefill = retellBriefingDefaults(
      ref,
      slot,
      smartSpeed: hasProgress
          ? defaultPlaybackSpeedFor(liveDifficulty, stageForDefault)
          : 1.0,
      smartRatio: smartRatio,
      smartSeconds: retellDefaultSeconds(stageForDefault),
    );
    showRetellBriefingSheet(
      context: context,
      sentences: sentences,
      defaultSeconds: prefill.seconds,
      defaultKeywordRatio: hasProgress ? prefill.ratio : null,
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
              loadKey: '${audioItem.id}:retell:planned',
            );
          },
      // 按计划学习路径才显示「跳过」按钮；自由练习路径无此回调
      onSkip: () async {
        await ref
            .read(learningProgressNotifierProvider.notifier)
            .skipCurrentSubStage(audioItemId);
      },
    );
  }
}
