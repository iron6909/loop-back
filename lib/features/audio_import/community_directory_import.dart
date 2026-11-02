/// 本地目录导入：只分类直接文件，复用现有配对和自然排序；合集在导入后原子创建。
library;

import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import '../../database/app_database.dart' as db;
import 'local_audio_file_picker.dart';
import 'subtitle_pairing.dart';

class CommunityDirectoryImport {
  CommunityDirectoryImport(PickedAudioDirectory directory)
    : name = directory.name,
      ignoredDirectories = directory.ignoredDirectories {
    final classified = classifyImportFiles(directory.files.map((f) => f.name));
    final names = {...classified.audioNames, ...classified.subtitleNames};
    files = directory.files.where((f) => names.contains(f.name)).toList()
      ..sort((a, b) => compareNatural(a.name, b.name));
    unsupportedCount =
        directory.unsupportedCount +
        classified.rejectedExtensions.length +
        classified.videoNames.length;
    audioCount = classified.audioNames.length;
  }

  final String name;
  final int ignoredDirectories;
  late final List<PlatformFile> files;
  late final int unsupportedCount;
  late final int audioCount;
  bool get isEmpty => audioCount == 0;

  /// 已有音频也可重复导入为合集引用；去重仍由现有音频入库层处理。
  Future<String?> commit(db.AppDatabase database, List<String> audioIds) async {
    if (isEmpty || audioIds.isEmpty) return null;
    final id = const Uuid().v4();
    return database.transaction(() async {
      await database.collectionDao.upsert(
        db.CollectionsCompanion.insert(
          id: id,
          name: name,
          createdDate: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      await database.collectionDao.addAudios(id, audioIds.toSet().toList());
      return id;
    });
  }
}
