import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Ref;
import 'package:path/path.dart' as p;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../database/app_database.dart' as db;
import '../../../database/providers.dart';
import '../../../services/app_logger.dart';
import '../../../utils/app_data_dir.dart';

part 'community_collection_repository.g.dart';

const _logTag = 'CommunityCollectionRepo';

/// 历史社区合集的本地清理。
///
/// 远端发现、同步与下载已停用；这里只负责按用户操作移除本地合集、音频行
/// 及对应学习数据，保证已有历史内容可读也可彻底删除。
class CommunityCollectionRepository {
  final db.AppDatabase _db;
  final Future<Directory> Function() _docsDir;

  CommunityCollectionRepository({
    required db.AppDatabase database,
    Future<Directory> Function()? docsDir,
  }) : _db = database,
       _docsDir = docsDir ?? getAppDataDirectory;

  /// 彻底移除社区合集及其未共享的本地媒体和学习数据。
  Future<void> remove(String localCollectionId) async {
    final orphanedAudioRows = <db.AudioItem>[];
    await _db.transaction(() async {
      final audioIds = await _db.collectionDao.getAudioIds(localCollectionId);
      for (final audioId in audioIds) {
        final audioRow = await _db.audioItemDao.getById(audioId);
        await (_db.delete(_db.collectionAudioItems)..where(
              (row) =>
                  row.collectionId.equals(localCollectionId) &
                  row.audioItemId.equals(audioId),
            ))
            .go();

        final remainingMembership =
            await (_db.select(_db.collectionAudioItems)
                  ..where((row) => row.audioItemId.equals(audioId))
                  ..limit(1))
                .getSingleOrNull();
        // 仅在最后一个合集关联移除后清理音频行和对应学习数据。
        if (remainingMembership != null) continue;

        for (final table in [
          'learning_progresses',
          'stage_completions',
          'playback_states',
          'bookmarks',
          'saved_words',
          'saved_sense_groups',
          'audio_item_tags',
        ]) {
          await _db.customStatement(
            'DELETE FROM $table WHERE audio_item_id = ?',
            [audioId],
          );
        }
        await _db.audioItemDao.hardDelete(audioId);
        if (audioRow != null) orphanedAudioRows.add(audioRow);
      }
      await _db.collectionDao.hardDelete(localCollectionId);
    });
    await _deleteLocalFiles(orphanedAudioRows);
  }

  Future<void> _deleteLocalFiles(List<db.AudioItem> rows) async {
    if (rows.isEmpty) return;
    final dir = await _docsDir();
    for (final row in rows) {
      for (final relativePath in [row.audioPath, row.transcriptPath]) {
        if (relativePath == null) continue;
        try {
          final file = File(p.join(dir.path, relativePath));
          if (await file.exists()) await file.delete();
        } catch (error) {
          AppLogger.log(_logTag, 'failed to delete $relativePath: $error');
        }
      }
    }
  }
}

@Riverpod(keepAlive: true)
CommunityCollectionRepository communityCollectionRepository(Ref ref) {
  return CommunityCollectionRepository(
    database: ref.watch(appDatabaseProvider),
  );
}
