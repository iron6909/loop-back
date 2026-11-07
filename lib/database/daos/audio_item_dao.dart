import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables/audio_items.dart';

part 'audio_item_dao.g.dart';

/// 字幕提交结果。
///
/// 只有 [committed] 表示字幕、词级时间戳、来源、语言与句词计数已整体落库。
enum TranscriptCommitResult {
  /// 已整体写入。
  committed,

  /// 提交前用户已取消，未写入。
  cancelled,

  /// 目标字幕已被其他操作（如用户导入或编辑）替换，未写入。
  conflict,
}

/// 音频元数据 DAO
/// 提供音频项的 CRUD 操作
@DriftAccessor(tables: [AudioItems])
class AudioItemDao extends DatabaseAccessor<AppDatabase>
    with _$AudioItemDaoMixin {
  AudioItemDao(super.db);

  /// 获取所有未删除的音频项
  Future<List<AudioItem>> getAllActive() {
    return (select(audioItems)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm.desc(t.isPinned),
            (t) => OrderingTerm.desc(t.addedDate),
          ]))
        .get();
  }

  /// 监听所有未删除的音频项
  Stream<List<AudioItem>> watchAllActive() {
    return (select(audioItems)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm.desc(t.isPinned),
            (t) => OrderingTerm.desc(t.addedDate),
          ]))
        .watch();
  }

  /// 根据 ID 获取音频项
  Future<AudioItem?> getById(String id) {
    return (select(
      audioItems,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// 根据社区合集中的 remoteAudioId 反查本地行。
  ///
  /// 同步时用于判断"远端新增音频在本地是否已存在"；忽略软删除行，避免复用
  /// 已从本地移除的条目。
  Future<AudioItem?> getByRemoteAudioId(String remoteAudioId) {
    return (select(audioItems)
          ..where(
            (t) => t.remoteAudioId.equals(remoteAudioId) & t.deletedAt.isNull(),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  /// 插入或更新音频项
  Future<void> upsert(AudioItemsCompanion entry) {
    return into(audioItems).insertOnConflictUpdate(entry);
  }

  /// 批量插入或更新音频项。
  ///
  /// 用 `insertOnConflictUpdate`（INSERT … ON CONFLICT DO UPDATE）语义：已存在行
  /// 只更新 companion 中显式携带的列，**不触碰** companion 未包含的大字段
  /// （`transcript_srt` / `word_timestamps_json`）。
  ///
  /// 不能用 `InsertMode.insertOrReplace`——它在 SQLite 是整行 DELETE+INSERT，会把
  /// 模型层不携带的大字段重置为 NULL，导致"句数词数还在但字幕内容丢失"。
  Future<void> batchInsert(List<AudioItemsCompanion> entries) async {
    await batch((b) {
      for (final entry in entries) {
        b.insert(audioItems, entry, onConflict: DoUpdate((_) => entry));
      }
    });
  }

  /// 批量硬删除音频项。
  ///
  /// 用于 Podcast 退订等大批量清理场景。调用方需在删除前完成文件清理和非 FK
  /// 上下文字段清理；本方法只删除 `audio_items` 行，并交给数据库级联清理子表。
  Future<void> hardDeleteMany(Set<String> ids) {
    if (ids.isEmpty) return Future.value();
    return (delete(audioItems)..where((t) => t.id.isIn(ids))).go();
  }

  /// 软删除音频项
  Future<void> softDelete(String id) {
    final now = DateTime.now();
    return (update(audioItems)..where((t) => t.id.equals(id))).write(
      AudioItemsCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        syncStatus: Value(2), // pendingDelete
      ),
    );
  }

  /// 硬删除音频项（真正从数据库移除）
  Future<void> hardDelete(String id) {
    return hardDeleteMany({id});
  }

  /// 获取指定音频的词级时间戳 JSON
  ///
  /// 独立查询，避免列表加载时读取大 JSON 字段。
  Future<String?> getWordTimestamps(String audioItemId) async {
    final query = select(audioItems)..where((t) => t.id.equals(audioItemId));
    final row = await query.getSingleOrNull();
    return row?.wordTimestampsJson;
  }

  /// 更新词级时间戳（独立更新，不影响其他字段）
  Future<void> updateWordTimestamps(String audioItemId, String? json) {
    return (update(audioItems)..where((t) => t.id.equals(audioItemId))).write(
      AudioItemsCompanion(wordTimestampsJson: Value(json)),
    );
  }

  /// 清除下载态：丢弃本地音频文件对应的派生元数据，把 item 还原为「未下载」。
  ///
  /// 用于社区/播客音频「删除音频」：仅回收本地音频文件占用，item 与字幕保留，
  /// 需要时可重新下载。清空的列都是「由被删音频文件派生、离开文件即失去意义」的：
  /// - [audioPath]：下载就绪的单一真实来源，置空即让列表重现下载按钮
  /// - [audioContentStatus]：文件内容有效性检测结果，重下后由 checkAudioContent 重测
  /// - [originalAudioSha256]：转码前原始文件指纹，文件已删；社区不用、播客/导入重下重算
  ///
  /// [keepAudioSha256] 为 true 时保留 [audioSha256]：社区音频的该指纹由 enroll 写入，
  /// 是重新下载时定位社区文件的稳定标识，清掉会导致重下
  /// 报错；播客/导入音频的指纹由本地文件派生，清空后由重下重算。
  ///
  /// **不触碰字幕 / 学习进度 / 时长**（字幕单独管理；时长在未下载态仍需在列表展示）。
  Future<void> clearDownloadState(
    String audioItemId, {
    required bool keepAudioSha256,
  }) {
    return (update(audioItems)..where((t) => t.id.equals(audioItemId))).write(
      AudioItemsCompanion(
        audioPath: const Value(null),
        audioContentStatus: const Value(null),
        originalAudioSha256: const Value(null),
        audioSha256: keepAudioSha256 ? const Value.absent() : const Value(null),
      ),
    );
  }

  /// 获取指定音频的字幕内容（完整 SRT 文本）。
  ///
  /// 独立查询，避免列表加载时读取大字段。
  Future<String?> getTranscriptSrt(String audioItemId) async {
    final query = select(audioItems)..where((t) => t.id.equals(audioItemId));
    final row = await query.getSingleOrNull();
    return row?.transcriptSrt;
  }

  /// 更新字幕内容（独立更新，不影响其他字段）。
  Future<void> updateTranscriptSrt(String audioItemId, String? srt) {
    return (update(audioItems)..where((t) => t.id.equals(audioItemId))).write(
      AudioItemsCompanion(transcriptSrt: Value(srt)),
    );
  }

  /// 查询需要 backfill 字幕内容的行：有遗留文件路径但 transcript_srt 列为空。
  ///
  /// 启动时全量 backfill 用，从这些行的 [transcriptPath] 文件读入 SRT。
  /// 列填满后返回空，后续启动为 no-op。
  Future<List<AudioItem>> getRowsNeedingSrtBackfill() {
    return (select(audioItems)..where(
          (t) =>
              t.transcriptSrt.isNull() &
              t.transcriptPath.isNotNull() &
              t.transcriptPath.isNotValue(''),
        ))
        .get();
  }

  /// 取所有行（含软删）的音频/字幕文件相对路径集合。
  ///
  /// 用于「清空缓存」时构造孤儿文件清扫的白名单：磁盘上不在此集合中的
  /// 文件即为孤儿。**不过滤 deletedAt**——软删行在硬删前仍持有其文件，
  /// 不能当作孤儿删除。空字符串/null 路径自动忽略。
  Future<Set<String>> getAllReferencedRelPaths() async {
    final rows = await (selectOnly(
      audioItems,
    )..addColumns([audioItems.audioPath, audioItems.transcriptPath])).get();
    final paths = <String>{};
    for (final row in rows) {
      final audioPath = row.read(audioItems.audioPath);
      if (audioPath != null && audioPath.isNotEmpty) paths.add(audioPath);
      final transcriptPath = row.read(audioItems.transcriptPath);
      if (transcriptPath != null && transcriptPath.isNotEmpty) {
        paths.add(transcriptPath);
      }
    }
    return paths;
  }

  /// 原子保存字幕内容：SRT + 词级时间戳，单事务写入两个大字段。
  ///
  /// 供 AI 转录、编辑保存等「字幕内容整体落库」场景使用，避免分两次写入中途崩溃
  /// 出现 SRT 与词级时间戳不一致。[wordTimestampsJson] 为 null 表示同时清空词级
  /// 时间戳（如编辑后无词级数据）。句/词计数、来源、路径等模型列由
  /// `audioLibraryProvider.updateAudioItem` 单独写入（与本方法列不相交）。
  Future<void> saveTranscriptContent(
    String audioItemId, {
    required String srt,
    required String? wordTimestampsJson,
  }) {
    return transaction(() async {
      await (update(audioItems)..where((t) => t.id.equals(audioItemId))).write(
        AudioItemsCompanion(
          transcriptSrt: Value(srt),
          wordTimestampsJson: Value(wordTimestampsJson),
        ),
      );
    });
  }

  /// 一次性提交转录结果：字幕、词级时间戳、来源、语言与句词计数同事务写入。
  ///
  /// 供字幕识别任务在完整成功时提交整体结果。事务内先复查两项前置条件，均不通过
  /// 则不写入并返回对应结果：
  /// - [isCancelled]：用户在写入前取消，已取消则不写库，避免「报了取消但字幕已被覆盖」。
  /// - [expectedSrt]：任务开始识别时观察到的字幕内容；当前内容已变说明用户在此期间
  ///   导入或编辑了字幕，保留用户较新的结果。
  /// 任一写入失败则整个事务回滚，原字幕与元数据保持不变。
  Future<TranscriptCommitResult> commitTranscription({
    required String audioItemId,
    required String srt,
    required String? wordTimestampsJson,
    required int transcriptSource,
    required String? transcriptLanguage,
    required int sentenceCount,
    required int wordCount,
    required String? expectedSrt,
    required bool Function() isCancelled,
  }) {
    return transaction(() async {
      final query = selectOnly(audioItems)
        ..addColumns([audioItems.transcriptSrt])
        ..where(audioItems.id.equals(audioItemId));
      final row = await query.getSingleOrNull();
      // 目标行已不存在（如被删除）时无可替换对象，按冲突处理。
      if (row == null) return TranscriptCommitResult.conflict;
      if (row.read(audioItems.transcriptSrt) != expectedSrt) {
        return TranscriptCommitResult.conflict;
      }
      if (isCancelled()) return TranscriptCommitResult.cancelled;
      await (update(audioItems)..where((t) => t.id.equals(audioItemId))).write(
        AudioItemsCompanion(
          transcriptSrt: Value(srt),
          wordTimestampsJson: Value(wordTimestampsJson),
          transcriptSource: Value(transcriptSource),
          transcriptLanguage: Value(transcriptLanguage),
          sentenceCount: Value(sentenceCount),
          wordCount: Value(wordCount),
          updatedAt: Value(DateTime.now()),
        ),
      );
      return TranscriptCommitResult.committed;
    });
  }
}
