/// 测试用 DAO 替身（共享）
///
/// 供 `test/helpers/mock_providers.dart` 和 `integration_test/helpers/test_notifiers.dart`
/// 共同使用。
///
/// 所有 DAO 替身默认返回空/零值，不访问真实数据库。
library;

import 'dart:async';

import 'package:echo_loop/database/app_database.dart'
    show AudioItem, Bookmark, BookmarksCompanion, SavedWord;
import 'package:echo_loop/database/daos/audio_item_dao.dart';
import 'package:echo_loop/database/daos/bookmark_dao.dart'
    show BookmarkDao, BookmarkWithAudio;
import 'package:echo_loop/database/daos/saved_word_dao.dart';
import 'package:echo_loop/database/daos/stage_completion_dao.dart'
    show StageCompletionDao, RecentCompletion;

// ========== FakeAudioItemDao ==========

/// 无操作 AudioItemDao — 默认查询返回 null/空；字幕内容与词级时间戳走内存存储，
/// 方便测试断言 transcript_srt 写入。
class FakeAudioItemDao implements AudioItemDao {
  /// 内存存储：audioItemId → 字幕 SRT 内容
  final Map<String, String?> transcriptSrtStore = {};

  /// 内存存储：audioItemId → 词级时间戳 JSON
  final Map<String, String?> wordTimestampsStore = {};

  /// 内存存储：audioItemId → 字幕来源与词时间戳来源（提交时写入）。
  final Map<String, int> transcriptSourceStore = {};
  final Map<String, int?> wordTimingSourceStore = {};

  @override
  Future<AudioItem?> getById(String id) async => null;

  @override
  Future<String?> getTranscriptSrt(String audioItemId) async =>
      transcriptSrtStore[audioItemId];

  @override
  Future<void> updateTranscriptSrt(String audioItemId, String? srt) async {
    transcriptSrtStore[audioItemId] = srt;
  }

  @override
  Future<String?> getWordTimestamps(String audioItemId) async =>
      wordTimestampsStore[audioItemId];

  @override
  Future<void> updateWordTimestamps(String audioItemId, String? json) async {
    wordTimestampsStore[audioItemId] = json;
  }

  @override
  Future<void> saveTranscriptContent(
    String audioItemId, {
    required String srt,
    required String? wordTimestampsJson,
    int? transcriptWordTimingSource,
  }) async {
    transcriptSrtStore[audioItemId] = srt;
    wordTimestampsStore[audioItemId] = wordTimestampsJson;
    if (transcriptWordTimingSource != null) {
      wordTimingSourceStore[audioItemId] = transcriptWordTimingSource;
    }
  }

  @override
  Future<TranscriptCommitResult> commitTranscription({
    required String audioItemId,
    required String srt,
    required String? wordTimestampsJson,
    required int transcriptSource,
    required int? transcriptWordTimingSource,
    required String? transcriptLanguage,
    required int sentenceCount,
    required int wordCount,
    required String? expectedSrt,
    required bool Function() isCancelled,
  }) async {
    if (transcriptSrtStore[audioItemId] != expectedSrt) {
      return TranscriptCommitResult.conflict;
    }
    if (isCancelled()) return TranscriptCommitResult.cancelled;
    transcriptSrtStore[audioItemId] = srt;
    wordTimestampsStore[audioItemId] = wordTimestampsJson;
    transcriptSourceStore[audioItemId] = transcriptSource;
    wordTimingSourceStore[audioItemId] = transcriptWordTimingSource;
    return TranscriptCommitResult.committed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<dynamic>.value();
}

// ========== FakeStageCompletionDao ==========

/// 无操作 StageCompletionDao — 所有查询返回空/即时完成
class FakeStageCompletionDao implements StageCompletionDao {
  @override
  Future<List<RecentCompletion>> getRecentCompletions(DateTime since) async =>
      [];

  @override
  Future<Map<String, Set<String>>> getCompletionKeysByAudio() async => {};

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

// ========== FakeBookmarkDao ==========

/// 测试用 BookmarkDao — 内存存储，支持 watchByAudioId
class FakeBookmarkDao implements BookmarkDao {
  /// 用于 watchByAudioId 返回的书签数量
  int bookmarkCount = 0;

  /// 内存存储：audioItemId → sentenceIndex 集合
  final Map<String, Set<int>> _store = {};

  @override
  Future<List<Bookmark>> getByAudioId(String audioItemId) {
    final indices = _store[audioItemId] ?? {};
    final bookmarks = indices
        .map(
          (i) => Bookmark(
            id: i,
            memorySubjectId: 'fake-subject-$audioItemId-$i',
            audioItemId: audioItemId,
            sentenceIndex: i,
            sentenceText: 'test sentence $i',
            startTime: 0.0,
            endTime: 1.0,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            syncStatus: 0,
          ),
        )
        .toList();
    return Future.value(bookmarks);
  }

  @override
  Future<Set<int>> getBookmarkedIndices(String audioItemId) {
    return Future.value(_store[audioItemId] ?? {});
  }

  @override
  Future<Bookmark?> getByAudioAndSentence(
    String audioItemId,
    int sentenceIndex,
  ) async {
    if (!(_store[audioItemId]?.contains(sentenceIndex) ?? false)) {
      return null;
    }
    return Bookmark(
      id: sentenceIndex,
      memorySubjectId: 'fake-subject-$audioItemId-$sentenceIndex',
      audioItemId: audioItemId,
      sentenceIndex: sentenceIndex,
      sentenceText: 'test sentence $sentenceIndex',
      startTime: 0.0,
      endTime: 1.0,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      syncStatus: 0,
    );
  }

  @override
  Future<void> addBookmark(BookmarksCompanion entry) {
    final audioId = entry.audioItemId.value;
    final index = entry.sentenceIndex.value;
    _store.putIfAbsent(audioId, () => {});
    _store[audioId]!.add(index);
    return Future.value();
  }

  @override
  Future<void> removeBookmark(String audioItemId, int sentenceIndex) {
    _store[audioItemId]?.remove(sentenceIndex);
    return Future.value();
  }

  @override
  Future<void> removeBookmarks(String audioItemId, Set<int> sentenceIndices) {
    _store[audioItemId]?.removeAll(sentenceIndices);
    return Future.value();
  }

  @override
  Future<void> removeAllForAudio(String audioItemId) {
    _store.remove(audioItemId);
    return Future.value();
  }

  @override
  Future<void> batchInsert(List<BookmarksCompanion> entries) {
    for (final entry in entries) {
      final audioId = entry.audioItemId.value;
      final index = entry.sentenceIndex.value;
      _store.putIfAbsent(audioId, () => {});
      _store[audioId]!.add(index);
    }
    return Future.value();
  }

  @override
  Stream<List<BookmarkWithAudio>> watchAllWithAudioName() {
    final allBookmarks = <BookmarkWithAudio>[];
    for (final entry in _store.entries) {
      for (final index in entry.value) {
        allBookmarks.add(
          BookmarkWithAudio(
            bookmark: Bookmark(
              id: index,
              memorySubjectId: 'fake-subject-${entry.key}-$index',
              audioItemId: entry.key,
              sentenceIndex: index,
              sentenceText: 'test sentence $index',
              startTime: 0.0,
              endTime: 1.0,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              syncStatus: 0,
            ),
            audioName: 'Test Audio',
          ),
        );
      }
    }
    return Stream.value(allBookmarks);
  }

  @override
  Future<int> countAll() {
    final total = _store.values.fold<int>(0, (sum, s) => sum + s.length);
    return Future.value(total);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final memberName = invocation.memberName.toString();
    if (memberName.contains('watchByAudioId')) {
      return Stream.value(List.generate(bookmarkCount, (i) => null));
    }
    return null;
  }
}

// ========== FakeSavedWordDao ==========

/// 空操作 SavedWordDao — 所有查询返回空
class FakeSavedWordDao implements SavedWordDao {
  @override
  Future<List<SavedWord>> getAll() => Future.value([]);

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}
