import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:loop_back/database/app_database.dart' as db;
import 'package:loop_back/features/community_collections/data/community_collection_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late db.AppDatabase database;
  late Directory directory;
  late CommunityCollectionRepository repository;

  setUp(() async {
    database = db.AppDatabase(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp('community_remove_');
    repository = CommunityCollectionRepository(
      database: database,
      docsDir: () async => directory,
    );
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<void> seedAudio(List<String> collectionIds) async {
    final now = DateTime(2026, 11, 5);
    await database.audioItemDao.upsert(
      db.AudioItemsCompanion.insert(
        id: 'audio-1',
        name: 'Historical episode',
        addedDate: now,
        updatedAt: now,
        remoteAudioId: const Value('remote-file-1'),
        audioPath: const Value('audio.m4a'),
        transcriptPath: const Value('transcript.srt'),
      ),
    );
    for (final id in collectionIds) {
      await database.collectionDao.upsert(
        db.CollectionsCompanion.insert(
          id: id,
          name: id,
          createdDate: now,
          updatedAt: now,
          source: const Value('community'),
          remoteId: Value('remote-$id'),
        ),
      );
      await database.collectionDao.addAudio(id, 'audio-1');
    }
    await database
        .into(database.learningProgresses)
        .insert(
          db.LearningProgressesCompanion(
            audioItemId: const Value('audio-1'),
            updatedAt: Value(now),
          ),
        );
    await File(p.join(directory.path, 'audio.m4a')).writeAsString('media');
    await File(
      p.join(directory.path, 'transcript.srt'),
    ).writeAsString('subtitle');
  }

  for (final remainingCount in [1, 2]) {
    test('移除历史合集会保留其余 $remainingCount 个合集共享的音频、文件和学习记录', () async {
      final remaining = List.generate(remainingCount, (i) => 'keep-$i');
      await seedAudio(['remove', ...remaining]);

      await repository.remove('remove');

      expect(await database.collectionDao.getById('remove'), isNull);
      for (final id in remaining) {
        expect(await database.collectionDao.getAudioIds(id), ['audio-1']);
      }
      expect(await database.audioItemDao.getById('audio-1'), isNotNull);
      expect(
        await database.learningProgressDao.getByAudioId('audio-1'),
        isNotNull,
      );
      expect(
        await File(p.join(directory.path, 'audio.m4a')).readAsString(),
        'media',
      );
      expect(
        await File(p.join(directory.path, 'transcript.srt')).readAsString(),
        'subtitle',
      );
    });
  }

  test('移除最后一个历史合集时清理音频、学习记录及本地文件', () async {
    await seedAudio(['remove']);

    await repository.remove('remove');

    expect(await database.collectionDao.getById('remove'), isNull);
    expect(await database.audioItemDao.getById('audio-1'), isNull);
    expect(await database.learningProgressDao.getByAudioId('audio-1'), isNull);
    expect(await File(p.join(directory.path, 'audio.m4a')).exists(), isFalse);
    expect(
      await File(p.join(directory.path, 'transcript.srt')).exists(),
      isFalse,
    );
  });

  test('重复移除或移除不存在的历史合集不会影响其它合集', () async {
    await seedAudio(['keep']);

    await repository.remove('missing');
    await repository.remove('missing');

    expect(await database.collectionDao.getAudioIds('keep'), ['audio-1']);
    expect(await database.audioItemDao.getById('audio-1'), isNotNull);
    expect(await File(p.join(directory.path, 'audio.m4a')).exists(), isTrue);
  });
}
