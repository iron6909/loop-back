/// 学习计划页的阶段级 provider。
///
/// 计划页、首次学习区块与复习区块都用这两条流；放在这里避免组件反过来 import 页面。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/providers.dart';

/// 指定音频的难句（书签）数量。
///
/// 使用 StreamProvider 监听 bookmarks 表变化，确保难句数实时更新。
final bookmarkCountProvider = StreamProvider.family.autoDispose<int, String>((
  ref,
  audioItemId,
) {
  final bookmarkDao = ref.watch(bookmarkDaoProvider);
  return bookmarkDao
      .watchByAudioId(audioItemId)
      .map((bookmarks) => bookmarks.length);
});

/// 查询指定音频各复习大阶段的最终完成时间。
///
/// 学习计划页据此为已完成的大阶段显示「X 天前」一类相对完成时间。
final reviewStageCompletionTimesProvider =
    StreamProvider.family<Map<String, DateTime>, String>((ref, audioItemId) {
      final dao = ref.watch(stageCompletionDaoProvider);
      return dao.watchStageCompletedAtByAudioId(audioItemId);
    });
