import '../../database/app_database.dart' as db;
import '../../database/daos/audio_item_dao.dart';
import '../../models/audio_item.dart' as model;
import 'local_audio_clip_player.dart';

/// 将数据库媒体行转换为播放层模型，保持所有本地媒体播放入口使用同一映射。
model.AudioItem audioItemFromDatabaseRow(db.AudioItem row) => model.AudioItem(
  id: row.id,
  name: row.name,
  audioPath: row.audioPath,
  transcriptPath: row.transcriptPath,
  addedDate: row.addedDate,
  totalDuration: row.totalDuration,
  sentenceCount: row.sentenceCount,
  wordCount: row.wordCount,
  isPinned: row.isPinned,
  transcriptSource: model.TranscriptSource.fromIndex(row.transcriptSource),
  transcriptWordTimingSource: model.TranscriptWordTimingSource.fromIndex(
    row.transcriptWordTimingSource,
  ),
  audioSha256: row.audioSha256,
  originalAudioSha256: row.originalAudioSha256,
  transcriptLanguage: row.transcriptLanguage,
);

/// 解析媒体文件并播放一个本地时间区间。
///
/// 收藏列表、收藏句复习等入口都通过此类访问 [LocalAudioClipPlayer]，避免
/// 各自重复实现数据库行映射、路径解析和失败结果处理。
class LocalAudioRangePlayer {
  LocalAudioRangePlayer({
    required AudioItemDao audioItemDao,
    required LocalAudioClipPlayer audioClipPlayer,
  }) : _audioItemDao = audioItemDao,
       _audioClipPlayer = audioClipPlayer;

  final AudioItemDao _audioItemDao;
  final LocalAudioClipPlayer _audioClipPlayer;

  Future<AudioPlaybackResult> play({
    required String audioItemId,
    required Duration start,
    required Duration end,
    String? playbackKey,
  }) async {
    final row = await _audioItemDao.getById(audioItemId);
    if (row == null) return AudioPlaybackResult.failed;
    final filePath = await audioItemFromDatabaseRow(row).getFullAudioPath();
    if (filePath == null) return AudioPlaybackResult.failed;
    return _audioClipPlayer.playRangeFile(
      filePath,
      start: start,
      end: end,
      playbackKey: playbackKey,
    );
  }
}
