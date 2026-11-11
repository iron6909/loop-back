import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/database/app_database.dart';
import 'package:loop_back/database/daos/bookmark_dao.dart';

/// 创建内存数据库用于测试（启用外键约束）
AppDatabase createTestDatabase() {
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
    db = createTestDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  group('AudioItemDao', () {
    test('插入并查询音频项', () async {
      final now = DateTime.now();
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Test Audio'),
          audioPath: Value('audios/test.mp3'),
          transcriptPath: Value('transcripts/test.srt'),
          addedDate: Value(now),
          totalDuration: Value(120),
          updatedAt: Value(now),
        ),
      );

      final items = await db.audioItemDao.getAllActive();
      expect(items.length, 1);
      expect(items.first.id, 'audio-1');
      expect(items.first.name, 'Test Audio');
      expect(items.first.audioPath, 'audios/test.mp3');
      expect(items.first.totalDuration, 120);
    });

    test('getById 返回正确的音频项', () async {
      final now = DateTime.now();
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Audio 1'),
          audioPath: Value('audios/1.mp3'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      final item = await db.audioItemDao.getById('audio-1');
      expect(item, isNotNull);
      expect(item!.name, 'Audio 1');

      final missing = await db.audioItemDao.getById('nonexistent');
      expect(missing, isNull);
    });

    test('getAllReferencedRelPaths 含软删行、忽略空路径', () async {
      final now = DateTime.now();
      // 活跃行：音频 + 字幕路径
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('a'),
          name: Value('A'),
          audioPath: Value('audios/imported/a.mp3'),
          transcriptPath: Value('transcripts/a.srt'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      // 软删行：文件仍应被视为「被引用」，不能当孤儿删
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('b'),
          name: Value('B'),
          audioPath: Value('audios/official/b.m4a'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      await db.audioItemDao.softDelete('b');
      // 无路径行：应被忽略
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('c'),
          name: Value('C'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      final paths = await db.audioItemDao.getAllReferencedRelPaths();

      expect(paths, {
        'audios/imported/a.mp3',
        'transcripts/a.srt',
        'audios/official/b.m4a',
      });
    });

    test('upsert 更新已存在的音频项', () async {
      final now = DateTime.now();
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Original'),
          audioPath: Value('audios/1.mp3'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Updated'),
          audioPath: Value('audios/1.mp3'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      final items = await db.audioItemDao.getAllActive();
      expect(items.length, 1);
      expect(items.first.name, 'Updated');
    });

    test('softDelete 设置 deletedAt，从 getAllActive 中排除', () async {
      final now = DateTime.now();
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('To Delete'),
          audioPath: Value('audios/1.mp3'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      await db.audioItemDao.softDelete('audio-1');

      final active = await db.audioItemDao.getAllActive();
      expect(active, isEmpty);

      // 但仍然可以通过 getById 找到
      final item = await db.audioItemDao.getById('audio-1');
      expect(item, isNotNull);
      expect(item!.deletedAt, isNotNull);
    });

    test('batchInsert 批量插入', () async {
      final now = DateTime.now();
      final entries = List.generate(
        5,
        (i) => AudioItemsCompanion(
          id: Value('audio-$i'),
          name: Value('Audio $i'),
          audioPath: Value('audios/$i.mp3'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      await db.audioItemDao.batchInsert(entries);

      final items = await db.audioItemDao.getAllActive();
      expect(items.length, 5);
    });

    test('batchInsert 更新已有行时保留 transcript_srt / word_timestamps 大字段', () async {
      final now = DateTime.now();
      // 1) 先写入一行并填入字幕大字段（模拟下载/AI 转录落库）
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Original'),
          audioPath: Value('audios/1.mp3'),
          sentenceCount: Value(10),
          wordCount: Value(100),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      await db.audioItemDao.saveTranscriptContent(
        'audio-1',
        srt: 'srt-content',
        wordTimestampsJson: '[{"word":"hi"}]',
      );

      // 2) 走 batchInsert 做一次"只带模型列"的回写（模拟 updateAudioItem/togglePin，
      //    companion 不含 transcript_srt / word_timestamps_json）
      await db.audioItemDao.batchInsert([
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Renamed'),
          audioPath: Value('audios/1.mp3'),
          sentenceCount: Value(10),
          wordCount: Value(100),
          isPinned: Value(true),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      ]);

      // 3) 模型列已更新，但大字段必须原样保留（不被整行 replace 清空）
      final item = await db.audioItemDao.getById('audio-1');
      expect(item!.name, 'Renamed');
      expect(item.isPinned, isTrue);
      expect(await db.audioItemDao.getTranscriptSrt('audio-1'), 'srt-content');
      expect(
        await db.audioItemDao.getWordTimestamps('audio-1'),
        '[{"word":"hi"}]',
      );
    });

    test('batchInsert 更新已有行不会级联删除合集 junction / 书签等子表', () async {
      final now = DateTime.now();
      // 音频 + 合集 + junction + 书签（模拟社区合集中已下载并加书签的音频）
      await db.collectionDao.upsert(
        CollectionsCompanion(
          id: const Value('col-1'),
          name: const Value('Official'),
          createdDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Audio 1'),
          audioPath: Value('audios/official/x.m4a'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      await db.collectionDao.addAudio('col-1', 'audio-1');
      await db.bookmarkDao.addBookmark(
        BookmarksCompanion(
          audioItemId: Value('audio-1'),
          sentenceIndex: Value(0),
          sentenceText: Value('hi'),
          startTime: Value(0.0),
          endTime: Value(1.0),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

      // 元数据回写（togglePin/rename/checkAudioContent 等都走此路径）
      await db.audioItemDao.batchInsert([
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Audio 1'),
          audioPath: Value('audios/official/x.m4a'),
          isPinned: Value(true),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      ]);

      // 整行替换会触发 onDelete cascade 删空子表；DO UPDATE 不会
      expect(await db.collectionDao.getAudioIds('col-1'), ['audio-1']);
      expect(await db.bookmarkDao.getBookmarkedIndices('audio-1'), {0});
      final item = await db.audioItemDao.getById('audio-1');
      expect(item!.isPinned, isTrue);
    });

    test('hardDeleteMany 批量删除并触发 junction cascade', () async {
      final now = DateTime.now();
      await db.collectionDao.upsert(
        CollectionsCompanion(
          id: const Value('col-1'),
          name: const Value('Collection 1'),
          createdDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      final entries = List.generate(
        3,
        (i) => AudioItemsCompanion(
          id: Value('audio-$i'),
          name: Value('Audio $i'),
          audioPath: Value('audios/$i.mp3'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      await db.audioItemDao.batchInsert(entries);
      await db.collectionDao.addAudios('col-1', [
        'audio-0',
        'audio-1',
        'audio-2',
      ]);

      await db.audioItemDao.hardDeleteMany({'audio-0', 'audio-1'});

      final items = await db.audioItemDao.getAllActive();
      expect(items.map((e) => e.id), ['audio-2']);
      expect(await db.collectionDao.getAudioIds('col-1'), ['audio-2']);
    });

    test('watchAllActive 响应数据变化', () async {
      final now = DateTime.now();
      final stream = db.audioItemDao.watchAllActive();

      // 初始为空
      expect(await stream.first, isEmpty);

      // 添加一个
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Audio 1'),
          audioPath: Value('audios/1.mp3'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      final items = await stream.first;
      expect(items.length, 1);
    });

    test('transcriptSrt get/update 往返', () async {
      final now = DateTime.now();
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Audio 1'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      // 初始为空
      expect(await db.audioItemDao.getTranscriptSrt('audio-1'), isNull);

      const srt = '1\n00:00:00,000 --> 00:00:01,000\nHello\n';
      await db.audioItemDao.updateTranscriptSrt('audio-1', srt);
      expect(await db.audioItemDao.getTranscriptSrt('audio-1'), srt);

      // 置空
      await db.audioItemDao.updateTranscriptSrt('audio-1', null);
      expect(await db.audioItemDao.getTranscriptSrt('audio-1'), isNull);
    });

    test('saveTranscriptContent 原子写入 SRT + 词级时间戳', () async {
      final now = DateTime.now();
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Audio 1'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      await db.audioItemDao.saveTranscriptContent(
        'audio-1',
        srt: 'srt-content',
        wordTimestampsJson: '[{"word":"hi"}]',
      );

      expect(await db.audioItemDao.getTranscriptSrt('audio-1'), 'srt-content');
      expect(
        await db.audioItemDao.getWordTimestamps('audio-1'),
        '[{"word":"hi"}]',
      );

      // wordTimestampsJson 传 null 同时清空词级时间戳
      await db.audioItemDao.saveTranscriptContent(
        'audio-1',
        srt: 'srt-2',
        wordTimestampsJson: null,
      );
      expect(await db.audioItemDao.getTranscriptSrt('audio-1'), 'srt-2');
      expect(await db.audioItemDao.getWordTimestamps('audio-1'), isNull);
    });

    test('getRowsNeedingSrtBackfill 只返回有 path 且 srt 为空的行', () async {
      final now = DateTime.now();
      // 行1：有 path、无 srt → 需要 backfill
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('need'),
          name: Value('need'),
          transcriptPath: Value('transcripts/need.srt'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      // 行2：有 path 且已有 srt → 不需要
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('done'),
          name: Value('done'),
          transcriptPath: Value('transcripts/done.srt'),
          transcriptSrt: Value('already'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      // 行3：无 path → 不需要
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('nopath'),
          name: Value('nopath'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      final rows = await db.audioItemDao.getRowsNeedingSrtBackfill();
      expect(rows.map((r) => r.id), ['need']);
    });
  });

  group('CollectionDao', () {
    test('插入并查询合集', () async {
      final now = DateTime.now();
      await db.collectionDao.upsert(
        CollectionsCompanion(
          id: Value('col-1'),
          name: Value('Test Collection'),
          createdDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      final collections = await db.collectionDao.getAllActive();
      expect(collections.length, 1);
      expect(collections.first.name, 'Test Collection');
    });

    test('addAudio 和 getAudioIds', () async {
      final now = DateTime.now();
      // 先插入音频项和合集
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Audio 1'),
          audioPath: Value('audios/1.mp3'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-2'),
          name: Value('Audio 2'),
          audioPath: Value('audios/2.mp3'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      await db.collectionDao.upsert(
        CollectionsCompanion(
          id: Value('col-1'),
          name: Value('Collection 1'),
          createdDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      await db.collectionDao.addAudio('col-1', 'audio-1');
      await db.collectionDao.addAudio('col-1', 'audio-2');

      final audioIds = await db.collectionDao.getAudioIds('col-1');
      expect(audioIds.length, 2);
      expect(audioIds, contains('audio-1'));
      expect(audioIds, contains('audio-2'));
    });

    test('addAudios 批量追加并保持顺序', () async {
      final now = DateTime.now();
      await db.collectionDao.upsert(
        CollectionsCompanion(
          id: const Value('col-1'),
          name: const Value('Collection 1'),
          createdDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      await db.audioItemDao.batchInsert(
        List.generate(
          4,
          (i) => AudioItemsCompanion(
            id: Value('audio-$i'),
            name: Value('Audio $i'),
            audioPath: Value('audios/$i.mp3'),
            addedDate: Value(now),
            updatedAt: Value(now),
          ),
        ),
      );

      await db.collectionDao.addAudio('col-1', 'audio-0');
      await db.collectionDao.addAudios('col-1', [
        'audio-1',
        'audio-2',
        'audio-3',
      ]);

      expect(await db.collectionDao.getAudioIds('col-1'), [
        'audio-0',
        'audio-1',
        'audio-2',
        'audio-3',
      ]);
    });

    test('removeAudio 从合集移除音频', () async {
      final now = DateTime.now();
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Audio 1'),
          audioPath: Value('audios/1.mp3'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      await db.collectionDao.upsert(
        CollectionsCompanion(
          id: Value('col-1'),
          name: Value('Collection 1'),
          createdDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      await db.collectionDao.addAudio('col-1', 'audio-1');
      await db.collectionDao.removeAudio('col-1', 'audio-1');

      final audioIds = await db.collectionDao.getAudioIds('col-1');
      expect(audioIds, isEmpty);
    });

    test('removeAudioFromAll 从所有合集移除', () async {
      final now = DateTime.now();
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Audio 1'),
          audioPath: Value('audios/1.mp3'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      for (int i = 1; i <= 3; i++) {
        await db.collectionDao.upsert(
          CollectionsCompanion(
            id: Value('col-$i'),
            name: Value('Collection $i'),
            createdDate: Value(now),
            updatedAt: Value(now),
          ),
        );
        await db.collectionDao.addAudio('col-$i', 'audio-1');
      }

      await db.collectionDao.removeAudioFromAll('audio-1');

      for (int i = 1; i <= 3; i++) {
        final ids = await db.collectionDao.getAudioIds('col-$i');
        expect(ids, isEmpty, reason: 'col-$i should be empty');
      }
    });

    test('getAudioCount 返回正确数量', () async {
      final now = DateTime.now();
      await db.collectionDao.upsert(
        CollectionsCompanion(
          id: Value('col-1'),
          name: Value('Collection 1'),
          createdDate: Value(now),
          updatedAt: Value(now),
        ),
      );

      for (int i = 0; i < 3; i++) {
        await db.audioItemDao.upsert(
          AudioItemsCompanion(
            id: Value('audio-$i'),
            name: Value('Audio $i'),
            audioPath: Value('audios/$i.mp3'),
            addedDate: Value(now),
            updatedAt: Value(now),
          ),
        );
        await db.collectionDao.addAudio('col-1', 'audio-$i');
      }

      final count = await db.collectionDao.getAudioCount('col-1');
      expect(count, 3);
    });

    test('CASCADE 删除：音频删除后 junction 自动清理', () async {
      final now = DateTime.now();
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Audio 1'),
          audioPath: Value('audios/1.mp3'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      await db.collectionDao.upsert(
        CollectionsCompanion(
          id: Value('col-1'),
          name: Value('Collection 1'),
          createdDate: Value(now),
          updatedAt: Value(now),
        ),
      );
      await db.collectionDao.addAudio('col-1', 'audio-1');

      // 硬删除音频
      await db.audioItemDao.hardDelete('audio-1');

      final ids = await db.collectionDao.getAudioIds('col-1');
      expect(ids, isEmpty);
    });
  });

  group('BookmarkDao', () {
    setUp(() async {
      // 先插入音频项
      final now = DateTime.now();
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Audio 1'),
          audioPath: Value('audios/1.mp3'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );
    });

    test('添加并查询书签', () async {
      final now = DateTime.now();
      await db.bookmarkDao.addBookmark(
        BookmarksCompanion(
          audioItemId: Value('audio-1'),
          sentenceIndex: Value(5),
          sentenceText: Value('Hello world'),
          startTime: Value(10.5),
          endTime: Value(12.3),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

      final bookmarks = await db.bookmarkDao.getByAudioId('audio-1');
      expect(bookmarks.length, 1);
      expect(bookmarks.first.sentenceIndex, 5);
      expect(bookmarks.first.sentenceText, 'Hello world');
      expect(bookmarks.first.startTime, closeTo(10.5, 0.01));
    });

    test('getBookmarkedIndices 返回索引集合', () async {
      final now = DateTime.now();
      for (int i in [2, 5, 8]) {
        await db.bookmarkDao.addBookmark(
          BookmarksCompanion(
            audioItemId: Value('audio-1'),
            sentenceIndex: Value(i),
            sentenceText: Value('Sentence $i'),
            startTime: Value(i * 1.0),
            endTime: Value(i * 1.0 + 1.0),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
      }

      final indices = await db.bookmarkDao.getBookmarkedIndices('audio-1');
      expect(indices, {2, 5, 8});
    });

    test('removeBookmark 移除单个书签', () async {
      final now = DateTime.now();
      await db.bookmarkDao.addBookmark(
        BookmarksCompanion(
          audioItemId: Value('audio-1'),
          sentenceIndex: Value(3),
          sentenceText: Value('Test'),
          startTime: Value(1.0),
          endTime: Value(2.0),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

      await db.bookmarkDao.removeBookmark('audio-1', 3);

      final indices = await db.bookmarkDao.getBookmarkedIndices('audio-1');
      expect(indices, isEmpty);
    });

    test('removeBookmarks 批量移除', () async {
      final now = DateTime.now();
      for (int i = 0; i < 5; i++) {
        await db.bookmarkDao.addBookmark(
          BookmarksCompanion(
            audioItemId: Value('audio-1'),
            sentenceIndex: Value(i),
            sentenceText: Value('Sentence $i'),
            startTime: Value(i * 1.0),
            endTime: Value(i * 1.0 + 1.0),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
      }

      await db.bookmarkDao.removeBookmarks('audio-1', {1, 3});

      final indices = await db.bookmarkDao.getBookmarkedIndices('audio-1');
      expect(indices, {0, 2, 4});
    });

    test('addBookmark 相同 audioItemId+sentenceIndex 执行 upsert', () async {
      final now = DateTime.now();
      // 第一次插入
      await db.bookmarkDao.addBookmark(
        BookmarksCompanion(
          audioItemId: Value('audio-1'),
          sentenceIndex: Value(5),
          sentenceText: Value('Hello'),
          startTime: Value(10.0),
          endTime: Value(12.0),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

      // 相同 key，不同 text
      await db.bookmarkDao.addBookmark(
        BookmarksCompanion(
          audioItemId: Value('audio-1'),
          sentenceIndex: Value(5),
          sentenceText: Value('Updated'),
          startTime: Value(10.0),
          endTime: Value(12.0),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

      final bookmarks = await db.bookmarkDao.getByAudioId('audio-1');
      expect(bookmarks.length, 1);
      expect(bookmarks.first.sentenceText, 'Updated');
    });

    test('batchInsert 更新已有书签时保留未携带列（deletedAt 软删标记）', () async {
      final now = DateTime.now();
      // 先添加并软删除一个书签
      await db.bookmarkDao.addBookmark(
        BookmarksCompanion(
          audioItemId: Value('audio-1'),
          sentenceIndex: Value(5),
          sentenceText: Value('old'),
          startTime: Value(1.0),
          endTime: Value(2.0),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
      await db.bookmarkDao.removeBookmark('audio-1', 5); // 置 deletedAt

      // batchInsert 同键、不携带 deletedAt（模拟迁移/回写）
      await db.bookmarkDao.batchInsert([
        BookmarksCompanion(
          audioItemId: Value('audio-1'),
          sentenceIndex: Value(5),
          sentenceText: Value('new'),
          startTime: Value(1.0),
          endTime: Value(2.0),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      ]);

      // 整行替换会清掉 deletedAt（书签复活）；DO UPDATE 应保留软删状态
      expect(await db.bookmarkDao.getBookmarkedIndices('audio-1'), isEmpty);
      final deleted = await db.bookmarkDao.getDeletedBookmarks(
        sortMode: RecycleBinSortMode.timeDesc,
      );
      expect(deleted.length, 1);
      expect(deleted.first.bookmark.sentenceText, 'new');
    });

    test('getDeletedBookmarks 返回已软删除的书签', () async {
      final now = DateTime.now();
      // 添加 3 个书签
      for (int i = 0; i < 3; i++) {
        await db.bookmarkDao.addBookmark(
          BookmarksCompanion(
            audioItemId: Value('audio-1'),
            sentenceIndex: Value(i),
            sentenceText: Value('Sentence $i'),
            startTime: Value(i * 1.0),
            endTime: Value(i * 1.0 + 1.0),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
      }

      // 软删除其中 2 个
      await db.bookmarkDao.removeBookmark('audio-1', 0);
      await db.bookmarkDao.removeBookmark('audio-1', 2);

      final deleted = await db.bookmarkDao.getDeletedBookmarks(
        sortMode: RecycleBinSortMode.timeDesc,
      );
      expect(deleted.length, 2);
      expect(deleted.map((d) => d.bookmark.sentenceIndex).toSet(), {0, 2});
      expect(deleted.first.audioName, 'Audio 1');
    });

    test('restoreBookmark 恢复已软删除的书签', () async {
      final now = DateTime.now();
      await db.bookmarkDao.addBookmark(
        BookmarksCompanion(
          audioItemId: Value('audio-1'),
          sentenceIndex: Value(0),
          sentenceText: Value('Test'),
          startTime: Value(0.0),
          endTime: Value(1.0),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

      await db.bookmarkDao.removeBookmark('audio-1', 0);
      expect(await db.bookmarkDao.getBookmarkedIndices('audio-1'), isEmpty);

      await db.bookmarkDao.restoreBookmark('audio-1', 0);
      expect(await db.bookmarkDao.getBookmarkedIndices('audio-1'), {0});
    });

    test('permanentlyDeleteBookmark 物理删除书签', () async {
      final now = DateTime.now();
      await db.bookmarkDao.addBookmark(
        BookmarksCompanion(
          audioItemId: Value('audio-1'),
          sentenceIndex: Value(0),
          sentenceText: Value('Test'),
          startTime: Value(0.0),
          endTime: Value(1.0),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

      await db.bookmarkDao.removeBookmark('audio-1', 0);
      await db.bookmarkDao.permanentlyDeleteBookmark('audio-1', 0);

      // 恢复后也查不到了（已物理删除）
      await db.bookmarkDao.restoreBookmark('audio-1', 0);
      expect(await db.bookmarkDao.getBookmarkedIndices('audio-1'), isEmpty);
    });

    test('permanentlyDeleteAllDeleted 清空回收站', () async {
      final now = DateTime.now();
      for (int i = 0; i < 3; i++) {
        await db.bookmarkDao.addBookmark(
          BookmarksCompanion(
            audioItemId: Value('audio-1'),
            sentenceIndex: Value(i),
            sentenceText: Value('Sentence $i'),
            startTime: Value(i * 1.0),
            endTime: Value(i * 1.0 + 1.0),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
      }

      // 软删除 2 个，保留 1 个
      await db.bookmarkDao.removeBookmark('audio-1', 0);
      await db.bookmarkDao.removeBookmark('audio-1', 2);

      await db.bookmarkDao.permanentlyDeleteAllDeleted();

      // 回收站为空
      final deleted = await db.bookmarkDao.getDeletedBookmarks(
        sortMode: RecycleBinSortMode.timeDesc,
      );
      expect(deleted, isEmpty);

      // 未删除的书签仍在
      expect(await db.bookmarkDao.getBookmarkedIndices('audio-1'), {1});
    });

    test('CASCADE 删除：音频删除后书签自动清理', () async {
      final now = DateTime.now();
      await db.bookmarkDao.addBookmark(
        BookmarksCompanion(
          audioItemId: Value('audio-1'),
          sentenceIndex: Value(0),
          sentenceText: Value('Test'),
          startTime: Value(0.0),
          endTime: Value(1.0),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );

      await db.audioItemDao.hardDelete('audio-1');

      final bookmarks = await db.bookmarkDao.getByAudioId('audio-1');
      expect(bookmarks, isEmpty);
    });
  });

  group('PlaybackStateDao', () {
    setUp(() async {
      final now = DateTime.now();
      await db.audioItemDao.upsert(
        AudioItemsCompanion(
          id: Value('audio-1'),
          name: Value('Audio 1'),
          audioPath: Value('audios/1.mp3'),
          addedDate: Value(now),
          updatedAt: Value(now),
        ),
      );
    });

    test('保存并查询播放状态', () async {
      await db.playbackStateDao.saveState(
        PlaybackStatesCompanion(
          audioItemId: Value('audio-1'),
          positionMs: Value(5000),
          playlistMode: Value(0),
          savedAt: Value(DateTime.now()),
        ),
      );

      final state = await db.playbackStateDao.getByAudioId('audio-1');
      expect(state, isNotNull);
      expect(state!.positionMs, 5000);
      expect(state.playlistMode, 0);
    });

    test('saveState 更新已存在的播放状态', () async {
      await db.playbackStateDao.saveState(
        PlaybackStatesCompanion(
          audioItemId: Value('audio-1'),
          positionMs: Value(1000),
          playlistMode: Value(0),
          savedAt: Value(DateTime.now()),
        ),
      );

      await db.playbackStateDao.saveState(
        PlaybackStatesCompanion(
          audioItemId: Value('audio-1'),
          positionMs: Value(9000),
          playlistMode: Value(1),
          savedAt: Value(DateTime.now()),
        ),
      );

      final state = await db.playbackStateDao.getByAudioId('audio-1');
      expect(state!.positionMs, 9000);
      expect(state.playlistMode, 1);
    });

    test('clearState 清除播放状态', () async {
      await db.playbackStateDao.saveState(
        PlaybackStatesCompanion(
          audioItemId: Value('audio-1'),
          positionMs: Value(5000),
          playlistMode: Value(0),
          savedAt: Value(DateTime.now()),
        ),
      );

      await db.playbackStateDao.clearState('audio-1');

      final state = await db.playbackStateDao.getByAudioId('audio-1');
      expect(state, isNull);
    });

    test('CASCADE 删除：音频删除后播放状态自动清理', () async {
      await db.playbackStateDao.saveState(
        PlaybackStatesCompanion(
          audioItemId: Value('audio-1'),
          positionMs: Value(5000),
          playlistMode: Value(0),
          savedAt: Value(DateTime.now()),
        ),
      );

      await db.audioItemDao.hardDelete('audio-1');

      final state = await db.playbackStateDao.getByAudioId('audio-1');
      expect(state, isNull);
    });
  });
}
