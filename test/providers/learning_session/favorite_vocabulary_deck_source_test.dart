import 'package:clock/clock.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:loop_back/database/app_database.dart' hide MemorySchedule;
import 'package:loop_back/features/memory_scheduler/adapters/fsrs/fsrs_memory_model_adapter.dart';
import 'package:loop_back/features/memory_scheduler/application/default_memory_scheduler.dart';
import 'package:loop_back/features/memory_scheduler/application/memory_model_registry.dart';
import 'package:loop_back/features/memory_scheduler/application/memory_scheduler.dart';
import 'package:loop_back/features/memory_scheduler/config/memory_profiles.dart';
import 'package:loop_back/features/memory_scheduler/data/drift_memory_schedule_repository.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_rating.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_scheduler_commands.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_namespaces.dart';
import 'package:loop_back/features/memory_scheduler/domain/memory_subject_ref.dart';
import 'package:loop_back/models/favorite_review_settings.dart';
import 'package:loop_back/providers/learning_session/favorite_vocabulary_deck_source.dart';
import 'package:loop_back/providers/learning_session/favorite_review_deck_source.dart';
import 'package:flutter_test/flutter_test.dart';

SavedWord _word(String memorySubjectId, String text, {DateTime? createdAt}) =>
    SavedWord(
      id: memorySubjectId.hashCode,
      word: text,
      memorySubjectId: memorySubjectId,
      practiceCount: 0,
      totalStudyMs: 0,
      viewedBack: false,
      createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
      updatedAt: createdAt ?? DateTime.utc(2026, 1, 1),
      syncStatus: 0,
    );

SavedSenseGroup _phrase(
  String memorySubjectId,
  String text, {
  DateTime? createdAt,
}) => SavedSenseGroup(
  id: memorySubjectId.hashCode,
  phraseText: text,
  memorySubjectId: memorySubjectId,
  displayText: text,
  practiceCount: 0,
  totalStudyMs: 0,
  viewedBack: false,
  createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
  updatedAt: createdAt ?? DateTime.utc(2026, 1, 1),
  syncStatus: 0,
);

void main() {
  late AppDatabase database;
  late MemoryScheduler scheduler;
  final now = DateTime.utc(2026, 8, 15, 8);

  setUp(() {
    database = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    scheduler = DefaultMemoryScheduler(
      repository: DriftMemoryScheduleRepository(database),
      profileRegistry: kMemoryProfileRegistry,
      modelRegistry: StaticMemoryModelRegistry(<FsrsMemoryModelAdapter>[
        FsrsMemoryModelAdapter(),
      ]),
      idGenerator: _IncrementingIdGenerator(),
      clock: Clock.fixed(now),
    );
  });

  tearDown(() => database.close());

  FavoriteVocabularyDeckSource source({
    FavoriteReviewSettings settings = const FavoriteReviewSettings(),
  }) => FavoriteVocabularyDeckSource(
    favoriteReviewDao: database.favoriteReviewDao,
    scheduler: scheduler,
    settings: settings,
    now: () => now,
  );

  Future<void> persistFavorites({
    List<SavedWord> words = const [],
    List<SavedSenseGroup> phrases = const [],
  }) async {
    for (final word in words) {
      await database
          .into(database.savedWords)
          .insert(
            SavedWordsCompanion.insert(
              word: word.word,
              memorySubjectId: Value(word.memorySubjectId),
              createdAt: word.createdAt,
              updatedAt: word.updatedAt,
              deletedAt: Value(word.deletedAt),
            ),
          );
      final subjectId = word.memorySubjectId;
      if (subjectId != null && subjectId.trim().isNotEmpty) {
        final subject = MemorySubjectRef(
          namespace: kSavedWordOrPhraseNamespace,
          subjectId: subjectId,
        );
        if (await scheduler.getSchedule(subject) == null) {
          await scheduler.ensureSchedule(
            EnsureMemoryScheduleCommand(
              subject: subject,
              profile: kFsrsDefaultProfileRef,
              occurredAt: now,
            ),
          );
        }
      }
    }
    for (final phrase in phrases) {
      await database
          .into(database.savedSenseGroups)
          .insert(
            SavedSenseGroupsCompanion.insert(
              phraseText: phrase.phraseText,
              memorySubjectId: Value(phrase.memorySubjectId),
              displayText: phrase.displayText,
              createdAt: phrase.createdAt,
              updatedAt: phrase.updatedAt,
              deletedAt: Value(phrase.deletedAt),
            ),
          );
      final subjectId = phrase.memorySubjectId;
      if (subjectId != null && subjectId.trim().isNotEmpty) {
        final subject = MemorySubjectRef(
          namespace: kSavedSenseGroupNamespace,
          subjectId: subjectId,
        );
        if (await scheduler.getSchedule(subject) == null) {
          await scheduler.ensureSchedule(
            EnsureMemoryScheduleCommand(
              subject: subject,
              profile: kFsrsDefaultProfileRef,
              occurredAt: now,
            ),
          );
        }
      }
    }
  }

  /// 让某个 subject 拥有一个到期时间在未来的既有 schedule。
  Future<void> pushDueIntoFuture(String namespace, String subjectId) async {
    final subject = MemorySubjectRef(
      namespace: namespace,
      subjectId: subjectId,
    );
    final schedule = await scheduler.ensureSchedule(
      EnsureMemoryScheduleCommand(
        subject: subject,
        profile: kFsrsDefaultProfileRef,
        occurredAt: now,
      ),
    );
    final preview = await scheduler.previewRatings(
      PreviewMemoryRatingsQuery(
        subject: subject,
        reviewedAt: now,
        expectedRevision: schedule.revision,
      ),
    );
    await scheduler.review(
      ReviewMemoryCommand(
        subject: subject,
        rating: MemoryRating.easy,
        preview: preview.easy,
        reviewedAt: now,
        responseTime: Duration.zero,
        operationId: 'seed-$subjectId',
        expectedRevision: schedule.revision,
      ),
    );
  }

  test('新卡立即到期，未到期的既有单词被过滤', () async {
    await pushDueIntoFuture(kSavedWordOrPhraseNamespace, 'future-word');
    await persistFavorites(
      words: [_word('future-word', 'apple'), _word('new-word', 'banana')],
    );
    final due = await source().load();

    expect(due, hasLength(1));
    expect(due.single.subject.subjectId, 'new-word');
    expect(due.single.content.displayText, 'banana');
  });

  test('单词和意群合并进同一个队列', () async {
    await persistFavorites(
      words: [_word('w1', 'apple')],
      phrases: [_phrase('p1', 'give up')],
    );
    final due = await source().load();

    expect(due.map((c) => c.subject.namespace).toSet(), {
      kSavedWordOrPhraseNamespace,
      kSavedSenseGroupNamespace,
    });
    expect(due.map((c) => c.content.displayText).toSet(), {'apple', 'give up'});
  });

  test('过滤非法项：空文本、缺失 memorySubjectId', () async {
    await persistFavorites(
      words: [
        _word('has-subject', 'valid'),
        SavedWord(
          id: 999,
          word: 'no-subject',
          practiceCount: 0,
          totalStudyMs: 0,
          viewedBack: false,
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
          syncStatus: 0,
        ),
      ],
      phrases: [_phrase('blank-text', '   ')],
    );
    final due = await source().load();

    expect(due, hasLength(1));
    expect(due.single.subject.subjectId, 'has-subject');
  });

  test('dueAt 排序：dueAt 相同时按 namespace:subjectId 稳定排序', () async {
    await persistFavorites(
      words: [_word('earlier', 'a')],
      phrases: [_phrase('also-new', 'b')],
    );
    final due = await source(
      settings: const FavoriteReviewSettings(order: FavoriteReviewOrder.dueAt),
    ).load();

    // 两张都是新卡，dueAt 相同（都等于 now），退化为按 "namespace:subjectId"
    // 稳定排序；'saved_sense_group:...' 字典序早于 'saved_word_or_phrase:...'。
    expect(due.map((c) => c.subject.subjectId), ['also-new', 'earlier']);
  });

  test('automatic 排序：收藏时间相同时使用稳定主体顺序', () async {
    await persistFavorites(
      words: [_word('z-last', 'z'), _word('a-first', 'a')],
    );

    final due = await source().load();

    expect(due.map((card) => card.subject.subjectId), ['a-first', 'z-last']);
  });

  test('无每日目标时返回所有到期单词和意群', () async {
    const settings = FavoriteReviewSettings();
    final words = [_word('first', 'a')];
    final phrases = [_phrase('second', 'b')];
    await persistFavorites(words: words, phrases: phrases);

    final firstLoad = await source(settings: settings).load();
    expect(firstLoad, hasLength(2));

    final secondLoad = await source(settings: settings).load();
    expect(secondLoad, hasLength(2));
  });

  test('通用 deck 返回所有到期内容', () async {
    const settings = FavoriteReviewSettings();
    final schedule = await scheduler.ensureSchedule(
      EnsureMemoryScheduleCommand(
        subject: MemorySubjectRef(
          namespace: kSavedSentenceNamespace,
          subjectId: 'sentence-1',
        ),
        profile: kFsrsDefaultProfileRef,
        occurredAt: now,
      ),
    );
    final sentenceDeck = FavoriteReviewDeckSource<String>(
      items: [
        FavoriteReviewDeckItem(
          content: 'sentence',
          subject: MemorySubjectRef(
            namespace: kSavedSentenceNamespace,
            subjectId: 'sentence-1',
          ),
          createdAt: now,
          schedule: schedule,
        ),
      ],
      scheduler: scheduler,
      settings: settings,
      now: () => now,
    );

    expect(await sentenceDeck.load(), hasLength(1));
    await persistFavorites(words: [_word('word-1', 'apple')]);
    final vocabulary = await source(settings: settings).load();
    expect(vocabulary, hasLength(1));
  });

  test('随机排序不丢卡也不重复', () async {
    await persistFavorites(
      words: [_word('r1', 'a'), _word('r2', 'b')],
      phrases: [_phrase('r3', 'c')],
    );
    final due = await source(
      settings: const FavoriteReviewSettings(order: FavoriteReviewOrder.random),
    ).load();
    expect(due.map((c) => c.subject.subjectId).toSet(), {'r1', 'r2', 'r3'});
  });
}

final class _IncrementingIdGenerator implements MemoryIdGenerator {
  int _next = 0;
  @override
  String newId() => 'id-${++_next}';
}
