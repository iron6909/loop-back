import 'dart:async';

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

void main() {
  late AppDatabase db;

  setUp(() {
    db = _createTestDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  /// 插入测试用音频项
  Future<void> insertAudio(String id, String name) async {
    final now = DateTime.now();
    await db.audioItemDao.upsert(
      AudioItemsCompanion(
        id: Value(id),
        name: Value(name),
        audioPath: Value('audios/$id.mp3'),
        addedDate: Value(now),
        updatedAt: Value(now),
      ),
    );
  }

  /// 插入一条步骤完成记录
  Future<void> insertCompletion({
    required String audioId,
    required String stage,
    required String subStage,
    required DateTime completedAt,
    int durationMs = 1000,
  }) async {
    await db.stageCompletionDao.insertRecord(
      StageCompletionsCompanion(
        audioItemId: Value(audioId),
        stage: Value(stage),
        subStage: Value(subStage),
        completedAt: Value(completedAt),
        durationMs: Value(durationMs),
      ),
    );
  }

  group('StageCompletionDao — getRecentCompletions', () {
    test('返回 since 之后的完成记录（含音频名称）', () async {
      await insertAudio('a1', 'Audio One');
      final now = DateTime(2026, 3, 25, 12, 0);
      await insertCompletion(
        audioId: 'a1',
        stage: 'firstLearn',
        subStage: 'blindListen',
        completedAt: now.subtract(const Duration(hours: 2)),
      );

      final results = await db.stageCompletionDao.getRecentCompletions(
        now.subtract(const Duration(hours: 24)),
      );

      expect(results, hasLength(1));
      expect(results.first.audioName, 'Audio One');
      expect(results.first.stage, 'firstLearn');
      expect(results.first.subStage, 'blindListen');
    });

    test('不返回 since 之前的记录', () async {
      await insertAudio('a1', 'Audio One');
      final now = DateTime(2026, 3, 25, 12, 0);
      await insertCompletion(
        audioId: 'a1',
        stage: 'firstLearn',
        subStage: 'blindListen',
        completedAt: now.subtract(const Duration(hours: 25)),
      );

      final results = await db.stageCompletionDao.getRecentCompletions(
        now.subtract(const Duration(hours: 24)),
      );

      expect(results, isEmpty);
    });

    test('按完成时间倒序排列', () async {
      await insertAudio('a1', 'Audio One');
      await insertAudio('a2', 'Audio Two');
      final now = DateTime(2026, 3, 25, 12, 0);

      await insertCompletion(
        audioId: 'a1',
        stage: 'firstLearn',
        subStage: 'blindListen',
        completedAt: now.subtract(const Duration(hours: 3)),
      );
      await insertCompletion(
        audioId: 'a2',
        stage: 'review0',
        subStage: 'intensiveListen',
        completedAt: now.subtract(const Duration(hours: 1)),
      );

      final results = await db.stageCompletionDao.getRecentCompletions(
        now.subtract(const Duration(hours: 24)),
      );

      expect(results, hasLength(2));
      expect(results[0].audioName, 'Audio Two');
      expect(results[1].audioName, 'Audio One');
    });

    test('无记录时返回空列表', () async {
      final now = DateTime(2026, 3, 25, 12, 0);
      final results = await db.stageCompletionDao.getRecentCompletions(
        now.subtract(const Duration(hours: 24)),
      );

      expect(results, isEmpty);
    });

    test('多条记录含正确的 durationMs', () async {
      await insertAudio('a1', 'Audio One');
      final now = DateTime(2026, 3, 25, 12, 0);

      await insertCompletion(
        audioId: 'a1',
        stage: 'firstLearn',
        subStage: 'blindListen',
        completedAt: now.subtract(const Duration(hours: 1)),
        durationMs: 5000,
      );

      final results = await db.stageCompletionDao.getRecentCompletions(
        now.subtract(const Duration(hours: 24)),
      );

      expect(results.first.durationMs, 5000);
    });
  });

  group('watchLatestCompletionAtByAudio', () {
    test('监听并返回每条材料最新的完成时间', () async {
      await insertAudio('a1', 'Audio One');
      final earlier = DateTime(2026, 3, 25, 11);
      final later = earlier.add(const Duration(hours: 1));
      await insertCompletion(
        audioId: 'a1',
        stage: 'firstLearn',
        subStage: 'blindListen',
        completedAt: earlier,
      );

      final events = StreamIterator(
        db.stageCompletionDao.watchLatestCompletionAtByAudio(),
      );
      addTearDown(() async => events.cancel());
      expect(await events.moveNext(), isTrue);
      expect(events.current, {'a1': earlier});

      await insertCompletion(
        audioId: 'a1',
        stage: 'firstLearn',
        subStage: 'intensiveListen',
        completedAt: later,
      );
      expect(await events.moveNext(), isTrue);
      expect(events.current, {'a1': later});
    });
  });

  group('getCompletionKeysByAudio', () {
    test('空表返回空 Map', () async {
      final result = await db.stageCompletionDao.getCompletionKeysByAudio();
      expect(result, isEmpty);
    });

    test('单音频多记录聚合为 Set', () async {
      await insertAudio('a1', 'Audio One');
      final now = DateTime(2026, 3, 25, 12, 0);
      await insertCompletion(
        audioId: 'a1',
        stage: 'firstLearn',
        subStage: 'blindListen',
        completedAt: now,
      );
      await insertCompletion(
        audioId: 'a1',
        stage: 'firstLearn',
        subStage: 'intensiveListen',
        completedAt: now.add(const Duration(minutes: 5)),
      );

      final result = await db.stageCompletionDao.getCompletionKeysByAudio();
      expect(result['a1'], {
        'firstLearn:blindListen',
        'firstLearn:intensiveListen',
      });
    });

    test('多音频独立分组', () async {
      await insertAudio('a1', 'Audio One');
      await insertAudio('a2', 'Audio Two');
      final now = DateTime(2026, 3, 25, 12, 0);
      await insertCompletion(
        audioId: 'a1',
        stage: 'firstLearn',
        subStage: 'blindListen',
        completedAt: now,
      );
      await insertCompletion(
        audioId: 'a2',
        stage: 'review0',
        subStage: 'reviewDifficultPractice',
        completedAt: now,
      );

      final result = await db.stageCompletionDao.getCompletionKeysByAudio();
      expect(result['a1'], {'firstLearn:blindListen'});
      expect(result['a2'], {'review0:reviewDifficultPractice'});
    });

    test('同一 (stage, subStage) 重复完成事件去重为单一 key', () async {
      await insertAudio('a1', 'Audio One');
      final now = DateTime(2026, 3, 25, 12, 0);
      await insertCompletion(
        audioId: 'a1',
        stage: 'firstLearn',
        subStage: 'blindListen',
        completedAt: now,
      );
      // 再次完成同一子步骤（模拟自由练习多次记录）
      await insertCompletion(
        audioId: 'a1',
        stage: 'firstLearn',
        subStage: 'blindListen',
        completedAt: now.add(const Duration(hours: 1)),
      );

      final result = await db.stageCompletionDao.getCompletionKeysByAudio();
      expect(result['a1'], {'firstLearn:blindListen'});
      expect(result['a1']!.length, 1);
    });
  });

  group('getStageCompletedAtByAudioId', () {
    test('空表返回空 Map', () async {
      final result = await db.stageCompletionDao.getStageCompletedAtByAudioId(
        'a1',
      );
      expect(result, isEmpty);
    });

    test('同一 stage 取最后一个子步骤完成时间', () async {
      await insertAudio('a1', 'Audio One');
      final base = DateTime(2026, 3, 25, 12, 0);
      await insertCompletion(
        audioId: 'a1',
        stage: 'review1',
        subStage: 'blindListen',
        completedAt: base,
      );
      await insertCompletion(
        audioId: 'a1',
        stage: 'review1',
        subStage: 'reviewDifficultPractice',
        completedAt: base.add(const Duration(hours: 1)),
      );

      final result = await db.stageCompletionDao.getStageCompletedAtByAudioId(
        'a1',
      );
      expect(result['review1'], base.add(const Duration(hours: 1)));
    });

    test('不同 stage 独立返回各自最终完成时间', () async {
      await insertAudio('a1', 'Audio One');
      final base = DateTime(2026, 3, 25, 12, 0);
      await insertCompletion(
        audioId: 'a1',
        stage: 'review0',
        subStage: 'blindListen',
        completedAt: base,
      );
      await insertCompletion(
        audioId: 'a1',
        stage: 'review1',
        subStage: 'blindListen',
        completedAt: base.add(const Duration(days: 2)),
      );

      final result = await db.stageCompletionDao.getStageCompletedAtByAudioId(
        'a1',
      );
      expect(result['review0'], base);
      expect(result['review1'], base.add(const Duration(days: 2)));
    });
  });

  group('watchStageCompletedAtByAudioId', () {
    test('插入完成记录后流自动发射新完成时间', () async {
      await insertAudio('a1', 'Audio One');
      final stream = db.stageCompletionDao.watchStageCompletedAtByAudioId('a1');

      // 首帧：空表
      await expectLater(stream.first, completion(isEmpty));

      final base = DateTime(2026, 3, 25, 12, 0);
      await insertCompletion(
        audioId: 'a1',
        stage: 'review1',
        subStage: 'blindListen',
        completedAt: base,
      );

      // 插入后流应发射含新完成时间的 Map
      final updated = await stream.firstWhere((m) => m.isNotEmpty);
      expect(updated['review1'], base);
    });

    test('同一 stage 取最后一个子步骤完成时间', () async {
      await insertAudio('a1', 'Audio One');
      final base = DateTime(2026, 3, 25, 12, 0);
      await insertCompletion(
        audioId: 'a1',
        stage: 'review1',
        subStage: 'blindListen',
        completedAt: base,
      );
      await insertCompletion(
        audioId: 'a1',
        stage: 'review1',
        subStage: 'reviewDifficultPractice',
        completedAt: base.add(const Duration(hours: 1)),
      );

      final result = await db.stageCompletionDao
          .watchStageCompletedAtByAudioId('a1')
          .first;
      expect(result['review1'], base.add(const Duration(hours: 1)));
    });
  });
}
