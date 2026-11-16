import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v62→v63：新增按视频保存的字幕遮罩设置表。
///
/// 上游为 EchoLoop 的 v67→v68；本仓 schema 独立编号，落到 63。
void main() {
  test('v62→v63 新增空的 video_subtitle_masks 表，且保留既有素材', () async {
    final directory = Directory.systemTemp.createTempSync('loop_back_v62_v63_');
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final file = File('${directory.path}/loop_back.db');

    var database = AppDatabase(NativeDatabase(file));
    await database.customSelect('SELECT 1').get();
    await database.close();

    // 还原 v62 结构：删除遮罩表、写入一条已有素材并回退版本号
    final raw = sqlite.sqlite3.open(file.path);
    try {
      raw.execute('DROP TABLE video_subtitle_masks');
      raw.execute(
        "INSERT INTO audio_items (id, name, added_date, updated_at) "
        "VALUES ('video-1', 'Video', 1767225600, 1767225600)",
      );
      raw.execute('PRAGMA user_version = 62');
    } finally {
      // 本仓 sqlite3 为 2.x，关闭裸连接用 dispose（上游 3.x 是 close）。
      raw.dispose();
    }

    database = AppDatabase(NativeDatabase(file));
    final audio = await database.audioItemDao.getById('video-1');
    final mask = await database.videoSubtitleMaskDao.getByAudioId('video-1');
    await database.close();

    expect(audio, isNotNull);
    expect(mask, isNull);

    final check = sqlite.sqlite3.open(file.path);
    try {
      final version = check.select('PRAGMA user_version').first.values.first;
      expect(version, greaterThanOrEqualTo(63));
    } finally {
      check.dispose();
    }
  });
}
