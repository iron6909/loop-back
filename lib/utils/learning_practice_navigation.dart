/// 学习任务页之间的导航：打开盲听/复述任务、等待退场、按完成情况触发评分邀请。
///
/// 首次学习、复习轮次与计划页状态都要走同一条链路，集中在这里避免三处各写一份
/// 路由与评分逻辑。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../database/enums.dart';
import '../features/rating_prompt/domain/rating_prompt_policy.dart';
import '../features/rating_prompt/rating_prompt_providers.dart';
import '../features/rating_prompt/rating_prompt_presentation_guard.dart';
import '../models/audio_item.dart';
import '../models/blind_listen_settings.dart';
import '../models/media_learning_startup.dart';
import '../models/media_load_result.dart';
import '../models/practice_completion_result.dart';
import '../models/sentence.dart';
import '../providers/learning_session/learning_session_provider.dart';
import '../router/app_router.dart';
import '../services/app_logger.dart';

/// 统一打开音频或视频盲听任务，避免首次学习与复习入口各自维护媒体分流。
///
/// 自由练习的补做目标只在媒体加载成功后写入，加载失败和取消不会提前改变学习进度语义。
Future<void> openBlindListenPractice({
  required BuildContext context,
  required WidgetRef ref,
  required AudioItem audioItem,
  required String? collectionId,
  required List<List<Sentence>> paragraphs,
  required BlindListenSettings settings,
  required LearningStage stage,
  required String loadKey,
  bool isFreePlay = false,
  LearningStage? catchUpStage,
  SubStageType? catchUpSubStage,
}) async {
  final session = ref.read(learningSessionProvider.notifier);
  final route = AppRoutes.blindListenPlayer(collectionId, audioItem.id);
  if (!context.mounted) return;
  context.push(
    route,
    extra: MediaLearningStartup(
      loadKey: loadKey,
      showVideoLoading: audioItem.isVideo,
      load: () async {
        final result = await session.enterBlindListenMode(
          audioItem,
          paragraphs: paragraphs,
          settings: settings,
          stage: stage,
          isFreePlay: isFreePlay,
        );
        if (result == MediaLoadResult.ready &&
            catchUpStage != null &&
            catchUpSubStage != null) {
          session.setCatchUp(catchUpStage, catchUpSubStage);
        }
        return result;
      },
      cancel: session.cancelBlindListenEntry,
    ),
  );
}

/// 通过统一媒体启动链路打开音频或视频复述任务。
Future<void> openRetellPractice({
  required BuildContext context,
  required WidgetRef ref,
  required AudioItem audioItem,
  required String? collectionId,
  required List<List<Sentence>> paragraphs,
  required String loadKey,
  bool isFreePlay = false,
  LearningStage? catchUpStage,
  SubStageType? catchUpSubStage,
}) async {
  final session = ref.read(learningSessionProvider.notifier);
  if (!context.mounted) return;
  await pushPracticeAndWaitForTransition(
    context,
    AppRoutes.retellPlayer(collectionId, audioItem.id),
    ref: ref,
    event: RatingPromptEvent.retellCompleted,
    extra: MediaLearningStartup(
      loadKey: loadKey,
      showVideoLoading: audioItem.isVideo,
      load: () => session.enterRetellMode(
        audioItem,
        paragraphs,
        isFreePlay: isFreePlay,
        catchUpStage: catchUpStage,
        catchUpSubStage: catchUpSubStage,
      ),
      cancel: session.cancelRetellEntry,
    ),
  );
}

/// 推入练习页，等待 root 退场完成后在原计划页仍可见时检查评分资格。
Future<void> pushPracticeAndWaitForTransition(
  BuildContext context,
  String route, {
  Object? extra,
  required WidgetRef ref,
  required RatingPromptEvent event,
}) async {
  final transition = rootRouteObserver.watchNextPop();
  final presentation = RatingPromptPresentationGuard(
    context: context,
    isRootRouteCurrent: () => transition.returnedToPreviousRoute,
  );
  try {
    final result = await context.push<PracticeCompletionResult>(
      route,
      extra: extra,
    );
    if (result == PracticeCompletionResult.completed) {
      await transition.completed;
      if (!context.mounted) return;
      await _requestRatingAfterPractice(
        ref,
        event,
        canPresent: () => presentation.canPresent,
      );
    }
  } finally {
    transition.cancel();
  }
}

/// 评分邀请失败由独立协调器处理，不改变练习完成后的导航行为。
Future<void> _requestRatingAfterPractice(
  WidgetRef ref,
  RatingPromptEvent event, {
  required bool Function() canPresent,
}) async {
  try {
    await ref
        .read(ratingPromptCoordinatorProvider)
        .maybeRequest(event, canPresent: canPresent);
  } catch (error, stackTrace) {
    AppLogger.log(
      'RatingPrompt',
      'coordinator unavailable error=$error\n$stackTrace',
    );
  }
}
