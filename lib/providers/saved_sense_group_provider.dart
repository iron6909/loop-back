import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../database/app_database.dart';
import '../database/providers.dart';
import 'favorite_vocabulary_lifecycle_provider.dart';

part 'saved_sense_group_provider.g.dart';

/// 收藏意群列表 Provider（流式）
///
/// 监听所有收藏意群的变化，按收藏时间倒序。
@Riverpod(keepAlive: true)
class SavedSenseGroupList extends _$SavedSenseGroupList {
  @override
  Stream<List<SavedSenseGroup>> build() {
    final dao = ref.watch(savedSenseGroupDaoProvider);
    return dao.watchAll();
  }

  /// 收藏意群
  ///
  /// [phraseText] 归一化后的文本（小写 + trim + 去句末标点）。
  /// [displayText] 原始文本（保留大小写）。
  /// [audioItemId] 必须指向收藏发生时存在的父音频。
  Future<void> saveSenseGroup({
    required String phraseText,
    required String displayText,
    required String audioItemId,
    int? sentenceIndex,
    String? sentenceText,
    int? sentenceStartMs,
    int? sentenceEndMs,
    int? groupStartMs,
    int? groupEndMs,
  }) async {
    await ref
        .read(favoriteVocabularyLifecycleProvider)
        .saveSenseGroup(
          phraseText: phraseText,
          displayText: displayText,
          audioItemId: audioItemId,
          sentenceIndex: sentenceIndex,
          sentenceText: sentenceText,
          sentenceStartMs: sentenceStartMs,
          sentenceEndMs: sentenceEndMs,
          groupStartMs: groupStartMs,
          groupEndMs: groupEndMs,
        );
  }

  /// 取消收藏意群
  Future<void> removeSenseGroup(String phraseText) => ref
      .read(favoriteVocabularyLifecycleProvider)
      .removeSenseGroup(phraseText);
}

/// 监听已收藏意群的归一化文本集合（用于 badge 染色与正文收藏标记）
///
/// 收藏标记是辅助功能：数据库未初始化（如宿主 widget 测试环境）时
/// 降级为空集，不崩宿主页（CLAUDE.md §7.18 默认值降级规则）。
/// 降级必须留日志——keepAlive 会把空集缓存整个会话，静默降级会把
/// 真实 DB 故障伪装成「用户没有收藏意群」。
@Riverpod(keepAlive: true)
class SavedSenseGroupTexts extends _$SavedSenseGroupTexts {
  @override
  Stream<Set<String>> build() {
    try {
      final dao = ref.watch(savedSenseGroupDaoProvider);
      return dao.watchSavedPhraseTexts();
    } catch (e) {
      debugPrint('[SavedSenseGroupTexts] 数据库不可用，收藏意群集合降级为空集: $e');
      return Stream.value(const <String>{});
    }
  }
}

/// 监听单个意群是否已收藏
///
/// `ref` 显式标注生成的 Ref 类型：未标注时源码侧视为 dynamic，
/// `avoid_dynamic_calls` 会把所有 watch 都报成动态调用。
@riverpod
Stream<bool> isSenseGroupSaved(IsSenseGroupSavedRef ref, String phraseText) {
  final dao = ref.watch(savedSenseGroupDaoProvider);
  return dao.watchIsSenseGroupSaved(phraseText);
}
