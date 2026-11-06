/// 目录导入：过滤、字幕优先级、自然排序与事务入库。
library;

import 'package:drift/native.dart';
import 'package:echo_loop/database/app_database.dart' as db;
import 'package:echo_loop/features/audio_import/community_directory_import.dart';
import 'package:echo_loop/features/audio_import/local_audio_file_picker.dart';
import 'package:echo_loop/features/audio_import/subtitle_pairing.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CommunityDirectoryImport plan(List<String> names) => CommunityDirectoryImport(
    PickedAudioDirectory(
      name: 'Lessons',
      ignoredDirectories: 2,
      files: [for (final name in names) PlatformFile(name: name, size: 1)],
    ),
  );

  test('自然排序、白名单过滤、字幕优先级与忽略计数', () {
    final result = plan([
      'lesson10.mp3',
      'lesson2.mp3',
      'lesson2.vtt',
      'lesson2.srt',
      'cover.jpg',
      'movie.mp4',
    ]);
    expect(
      result.files.where((f) => f.name.endsWith('.mp3')).map((f) => f.name),
      ['lesson2.mp3', 'lesson10.mp3'],
    );
    expect(
      matchSubtitlesForAudios(result.files.map((f) => f.name))['lesson2.mp3'],
      'lesson2.srt',
    );
    expect(result.unsupportedCount, 2);
    expect(result.ignoredDirectories, 2);
  });

  test('空目录或全部过滤不创建合集；全重复仍可引用已有音频', () async {
    final database = db.AppDatabase(
      NativeDatabase.memory(
        setup: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    addTearDown(database.close);
    expect(await plan(['cover.jpg']).commit(database, ['existing']), isNull);
    expect(await database.collectionDao.getAllActive(), isEmpty);
    expect(await plan(['a.mp3']).commit(database, []), isNull);
    await database.audioItemDao.upsert(
      db.AudioItemsCompanion.insert(
        id: 'existing',
        name: 'Existing',
        addedDate: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
    final id = await plan([
      'lesson1.mp3',
    ]).commit(database, ['existing', 'existing']);
    expect(await database.collectionDao.getAudioIds(id ?? ''), ['existing']);
    expect(
      (await database.collectionDao.getAllActive()).single.name,
      'Lessons',
    );
  });

  test('关联写入失败回滚合集，不留下半成品', () async {
    final database = db.AppDatabase(
      NativeDatabase.memory(
        setup: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    addTearDown(database.close);
    await expectLater(
      plan(['a.mp3']).commit(database, ['missing']),
      throwsA(anything),
    );
    expect(await database.collectionDao.getAllActive(), isEmpty);
    await database.audioItemDao.upsert(
      db.AudioItemsCompanion.insert(
        id: 'missing',
        name: 'Recovered',
        addedDate: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
    final id = await plan(['a.mp3']).commit(database, ['missing']);
    expect((await database.collectionDao.getAllActive()).length, 1);
    expect(await database.collectionDao.getAudioIds(id ?? ''), ['missing']);
  });
}
