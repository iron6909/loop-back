import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/database/app_database.dart';

/// 创建内存数据库用于测试（启用外键约束）
AppDatabase _createTestDatabase() {
  return AppDatabase(
    NativeDatabase.memory(
      setup: (db) {
        db.execute('PRAGMA foreign_keys = ON');
      },
    ),
  );
}

/// 插入测试用音频项（LearningProgresses 依赖 AudioItems 外键）
Future<void> _insertTestAudio(AppDatabase db, String id) async {
  final now = DateTime.now();
  await db.audioItemDao.upsert(
    AudioItemsCompanion(
      id: Value(id),
      name: Value('Test Audio $id'),
      audioPath: Value('audios/$id.mp3'),
      addedDate: Value(now),
      updatedAt: Value(now),
    ),
  );
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = _createTestDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  group('LearningProgressDao', () {
    test('插入并查询学习进度', () async {
      await _insertTestAudio(db, 'audio-1');
      final now = DateTime.now();

      await db.learningProgressDao.upsert(
        LearningProgressesCompanion(
          audioItemId: const Value('audio-1'),
          currentStage: const Value('firstLearn'),
          currentSubStage: const Value('blindListen'),
          difficulty: const Value(1),
          updatedAt: Value(now),
        ),
      );

      final result = await db.learningProgressDao.getByAudioId('audio-1');
      expect(result, isNotNull);
      expect(result!.audioItemId, 'audio-1');
      expect(result.currentStage, 'firstLearn');
      expect(result.currentSubStage, 'blindListen');
      expect(result.difficulty, 1);
      expect(result.totalStudyDurationMs, 0); // 默认值
    });

    test('getByAudioId 不存在时返回 null', () async {
      final result = await db.learningProgressDao.getByAudioId('nonexistent');
      expect(result, isNull);
    });

    test('getAll 返回所有进度', () async {
      await _insertTestAudio(db, 'audio-1');
      await _insertTestAudio(db, 'audio-2');
      final now = DateTime.now();

      await db.learningProgressDao.upsert(
        LearningProgressesCompanion(
          audioItemId: const Value('audio-1'),
          currentStage: const Value('firstLearn'),
          currentSubStage: const Value('intensiveListen'),
          difficulty: const Value(1),
          updatedAt: Value(now),
        ),
      );
      await db.learningProgressDao.upsert(
        LearningProgressesCompanion(
          audioItemId: const Value('audio-2'),
          currentStage: const Value('review2'),
          currentSubStage: const Value('retell'),
          difficulty: const Value(0),
          updatedAt: Value(now),
        ),
      );

      final results = await db.learningProgressDao.getAll();
      expect(results.length, 2);
    });

    test('upsert 更新已存在的进度', () async {
      await _insertTestAudio(db, 'audio-1');
      final now = DateTime.now();

      await db.learningProgressDao.upsert(
        LearningProgressesCompanion(
          audioItemId: const Value('audio-1'),
          currentStage: const Value('firstLearn'),
          currentSubStage: const Value('blindListen'),
          difficulty: const Value(1),
          updatedAt: Value(now),
        ),
      );

      // 更新进度
      await db.learningProgressDao.upsert(
        LearningProgressesCompanion(
          audioItemId: const Value('audio-1'),
          currentStage: const Value('review0'),
          currentSubStage: const Value('listenAndRepeat'),
          difficulty: const Value(2),
          updatedAt: Value(now),
        ),
      );

      final result = await db.learningProgressDao.getByAudioId('audio-1');
      expect(result!.currentStage, 'review0');
      expect(result.currentSubStage, 'listenAndRepeat');
      expect(result.difficulty, 2);

      // 确认没有重复记录
      final all = await db.learningProgressDao.getAll();
      expect(all.length, 1);
    });

    test('deleteByAudioId 删除指定进度', () async {
      await _insertTestAudio(db, 'audio-1');
      final now = DateTime.now();

      await db.learningProgressDao.upsert(
        LearningProgressesCompanion(
          audioItemId: const Value('audio-1'),
          currentStage: const Value('firstLearn'),
          currentSubStage: const Value('blindListen'),
          difficulty: const Value(1),
          updatedAt: Value(now),
        ),
      );

      await db.learningProgressDao.deleteByAudioId('audio-1');

      final result = await db.learningProgressDao.getByAudioId('audio-1');
      expect(result, isNull);
    });

    test('CASCADE 删除 — 删除音频时自动清理进度', () async {
      await _insertTestAudio(db, 'audio-1');
      final now = DateTime.now();

      await db.learningProgressDao.upsert(
        LearningProgressesCompanion(
          audioItemId: const Value('audio-1'),
          currentStage: const Value('review1'),
          currentSubStage: const Value('listenAndRepeat'),
          difficulty: const Value(1),
          updatedAt: Value(now),
        ),
      );

      // 硬删除音频
      await db.audioItemDao.hardDelete('audio-1');

      // 进度应被级联删除
      final result = await db.learningProgressDao.getByAudioId('audio-1');
      expect(result, isNull);
    });

    test('firstLearnCompletedAt 可为 null 或有值', () async {
      await _insertTestAudio(db, 'audio-1');
      final now = DateTime.now();

      // 初始时为 null
      await db.learningProgressDao.upsert(
        LearningProgressesCompanion(
          audioItemId: const Value('audio-1'),
          currentStage: const Value('firstLearn'),
          currentSubStage: const Value('blindListen'),
          difficulty: const Value(1),
          updatedAt: Value(now),
        ),
      );

      var result = await db.learningProgressDao.getByAudioId('audio-1');
      expect(result!.firstLearnCompletedAt, isNull);

      // 更新为有值
      await db.learningProgressDao.upsert(
        LearningProgressesCompanion(
          audioItemId: const Value('audio-1'),
          currentStage: const Value('review0'),
          currentSubStage: const Value('blindListen'),
          difficulty: const Value(1),
          firstLearnCompletedAt: Value(now),
          updatedAt: Value(now),
        ),
      );

      result = await db.learningProgressDao.getByAudioId('audio-1');
      expect(result!.firstLearnCompletedAt, isNotNull);
    });

    test(
      '新增字段 — lastStageCompletedAt / currentStageStartedAt / totalStudyDurationMs',
      () async {
        await _insertTestAudio(db, 'audio-1');
        final now = DateTime.now();
        final startedAt = now.subtract(const Duration(minutes: 10));

        await db.learningProgressDao.upsert(
          LearningProgressesCompanion(
            audioItemId: const Value('audio-1'),
            currentStage: const Value('review1'),
            currentSubStage: const Value('blindListen'),
            difficulty: const Value(1),
            lastStageCompletedAt: Value(now),
            currentStageStartedAt: Value(startedAt),
            totalStudyDurationMs: const Value(600000),
            updatedAt: Value(now),
          ),
        );

        final result = await db.learningProgressDao.getByAudioId('audio-1');
        expect(result, isNotNull);
        expect(result!.lastStageCompletedAt, isNotNull);
        expect(result.currentStageStartedAt, isNotNull);
        expect(result.totalStudyDurationMs, 600000);
      },
    );
  });

  group('StageCompletionDao', () {
    test('插入并查询完成记录', () async {
      await _insertTestAudio(db, 'audio-1');
      final now = DateTime.now();

      await db.stageCompletionDao.insertRecord(
        StageCompletionsCompanion(
          audioItemId: const Value('audio-1'),
          stage: const Value('firstLearn'),
          subStage: const Value('blindListen'),
          completedAt: Value(now),
          durationMs: const Value(120000),
        ),
      );

      final results = await db.stageCompletionDao.getByAudioId('audio-1');
      expect(results.length, 1);
      expect(results[0].audioItemId, 'audio-1');
      expect(results[0].stage, 'firstLearn');
      expect(results[0].subStage, 'blindListen');
      expect(results[0].durationMs, 120000);
    });

    test('getByAudioId 按完成时间升序排列', () async {
      await _insertTestAudio(db, 'audio-1');
      final t1 = DateTime(2026, 2, 20, 10, 0);
      final t2 = DateTime(2026, 2, 20, 11, 0);
      final t3 = DateTime(2026, 2, 20, 12, 0);

      // 故意乱序插入
      await db.stageCompletionDao.insertRecord(
        StageCompletionsCompanion(
          audioItemId: const Value('audio-1'),
          stage: const Value('firstLearn'),
          subStage: const Value('intensiveListen'),
          completedAt: Value(t2),
        ),
      );
      await db.stageCompletionDao.insertRecord(
        StageCompletionsCompanion(
          audioItemId: const Value('audio-1'),
          stage: const Value('firstLearn'),
          subStage: const Value('blindListen'),
          completedAt: Value(t1),
        ),
      );
      await db.stageCompletionDao.insertRecord(
        StageCompletionsCompanion(
          audioItemId: const Value('audio-1'),
          stage: const Value('firstLearn'),
          subStage: const Value('listenAndRepeat'),
          completedAt: Value(t3),
        ),
      );

      final results = await db.stageCompletionDao.getByAudioId('audio-1');
      expect(results.length, 3);
      expect(results[0].subStage, 'blindListen');
      expect(results[1].subStage, 'intensiveListen');
      expect(results[2].subStage, 'listenAndRepeat');
    });

    test('getByAudioId 不存在时返回空列表', () async {
      final results = await db.stageCompletionDao.getByAudioId('nonexistent');
      expect(results, isEmpty);
    });

    test('deleteByAudioId 删除指定音频的所有记录', () async {
      await _insertTestAudio(db, 'audio-1');
      await _insertTestAudio(db, 'audio-2');
      final now = DateTime.now();

      // 给两个音频各插入记录
      await db.stageCompletionDao.insertRecord(
        StageCompletionsCompanion(
          audioItemId: const Value('audio-1'),
          stage: const Value('firstLearn'),
          subStage: const Value('blindListen'),
          completedAt: Value(now),
        ),
      );
      await db.stageCompletionDao.insertRecord(
        StageCompletionsCompanion(
          audioItemId: const Value('audio-2'),
          stage: const Value('firstLearn'),
          subStage: const Value('blindListen'),
          completedAt: Value(now),
        ),
      );

      await db.stageCompletionDao.deleteByAudioId('audio-1');

      final results1 = await db.stageCompletionDao.getByAudioId('audio-1');
      expect(results1, isEmpty);

      // audio-2 不受影响
      final results2 = await db.stageCompletionDao.getByAudioId('audio-2');
      expect(results2.length, 1);
    });

    test('CASCADE 删除 — 删除音频时自动清理完成记录', () async {
      await _insertTestAudio(db, 'audio-1');
      final now = DateTime.now();

      await db.stageCompletionDao.insertRecord(
        StageCompletionsCompanion(
          audioItemId: const Value('audio-1'),
          stage: const Value('firstLearn'),
          subStage: const Value('blindListen'),
          completedAt: Value(now),
        ),
      );

      await db.audioItemDao.hardDelete('audio-1');

      final results = await db.stageCompletionDao.getByAudioId('audio-1');
      expect(results, isEmpty);
    });

    test('durationMs 默认值为 0', () async {
      await _insertTestAudio(db, 'audio-1');
      final now = DateTime.now();

      await db.stageCompletionDao.insertRecord(
        StageCompletionsCompanion(
          audioItemId: const Value('audio-1'),
          stage: const Value('firstLearn'),
          subStage: const Value('blindListen'),
          completedAt: Value(now),
          // 不设置 durationMs，使用默认值
        ),
      );

      final results = await db.stageCompletionDao.getByAudioId('audio-1');
      expect(results[0].durationMs, 0);
    });
  });
}
