import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/database/app_database.dart' as db;
import 'package:loop_back/database/daos/audio_item_dao.dart';
import 'package:loop_back/models/audio_item.dart' show TranscriptSource;
import 'package:loop_back/models/word_timestamp.dart';
import 'package:loop_back/utils/sense_group_service.dart';

import '../helpers/mock_providers.dart';

void main() {
  group('SenseGroupService.fetchWordTimestamps', () {
    test('本地字幕缺少词级时间戳时，从 SRT 懒生成并回写', () async {
      const srt =
          '1\n'
          '00:00:01,000 --> 00:00:02,000\n'
          'Hello, world.\n';
      final dao = _AudioItemDaoWithRow(
        _audioItem(
          transcriptSource: TranscriptSource.local.index,
          transcriptSrt: srt,
        ),
      );
      final service = SenseGroupService();

      final words = await service.fetchWordTimestamps(
        audioItemId: 'audio-1',
        dao: dao,
      );

      expect(words, isNotNull);
      expect(words!.map((w) => w.word), ['Hello,', 'world.']);
      expect(words.first.startTime, const Duration(milliseconds: 1000));
      expect(words.last.endTime, const Duration(milliseconds: 2000));

      final stored = dao.wordTimestampsStore['audio-1'];
      expect(stored, isNotNull);
      final decoded = decodeWordTimestamps(stored!);
      expect(decoded!.map((w) => w.word), ['Hello,', 'world.']);
    });

    test('历史云端字幕缺时间戳也只从 SRT 合成', () async {
      final dao = _AudioItemDaoWithRow(
        _audioItem(
          transcriptSource: TranscriptSource.ai.index,
          transcriptSrt: '1\n00:00:00,000 --> 00:00:01,000\nOld words\n',
        ),
      );
      final words = await SenseGroupService().fetchWordTimestamps(
        audioItemId: 'audio-1',
        dao: dao,
      );
      expect(words?.map((w) => w.word), ['Old', 'words']);
    });

    test('已有词级时间戳时，非 AI 字幕也直接使用 DB 数据', () async {
      final existing = encodeWordTimestamps([
        const WordTimestamp(
          word: 'Cached.',
          startTime: Duration(milliseconds: 100),
          endTime: Duration(milliseconds: 300),
        ),
      ]);
      final dao = _AudioItemDaoWithRow(
        _audioItem(
          transcriptSource: TranscriptSource.local.index,
          wordTimestampsJson: existing,
        ),
      );
      final service = SenseGroupService();

      final words = await service.fetchWordTimestamps(
        audioItemId: 'audio-1',
        dao: dao,
      );

      expect(words!.single.word, 'Cached.');
    });
  });
}

class _AudioItemDaoWithRow extends TestAudioItemDao implements AudioItemDao {
  _AudioItemDaoWithRow(this.row) {
    transcriptSrtStore[row.id] = row.transcriptSrt;
    wordTimestampsStore[row.id] = row.wordTimestampsJson;
  }

  final db.AudioItem row;

  @override
  Future<db.AudioItem?> getById(String id) async {
    final updatedWords = wordTimestampsStore[id];
    return row.copyWith(wordTimestampsJson: Value(updatedWords));
  }
}

db.AudioItem _audioItem({
  int? transcriptSource,
  String? transcriptSrt,
  String? wordTimestampsJson,
}) {
  return db.AudioItem(
    id: 'audio-1',
    name: 'Audio 1',
    audioPath: 'audios/audio.mp3',
    transcriptPath: null,
    addedDate: DateTime(2026, 1, 1),
    totalDuration: 2,
    sentenceCount: 1,
    wordCount: 2,
    isPinned: false,
    transcriptSource: transcriptSource,
    audioSha256: null,
    transcriptLanguage: null,
    updatedAt: DateTime(2026, 1, 1),
    deletedAt: null,
    wordTimestampsJson: wordTimestampsJson,
    transcriptSrt: transcriptSrt,
    syncStatus: 0,
    remoteAudioId: null,
    originalDate: null,
  );
}
