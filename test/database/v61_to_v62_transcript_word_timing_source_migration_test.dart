import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:echo_loop/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v61→v62：追加字幕整体词时间戳来源列。
///
/// 只加可空列：旧字幕的来源整数、内容与学习数据保持原样，缺标记即「未知」，
/// 不能把历史 ai 重解释成模型对齐，也不能给旧行编造一个来源。
void main() {
  test('v61→v62 添加可空的词时间戳来源列并保留旧字幕与来源值', () async {
    final directory = Directory.systemTemp.createTempSync('fluency_v61_v62_');
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final file = File('${directory.path}/echo_loop.db');
    var database = AppDatabase(NativeDatabase(file));
    await database.audioItemDao.upsert(
      AudioItemsCompanion(
        id: const Value('legacy-ai'),
        name: const Value('Bundled example'),
        addedDate: Value(DateTime.utc(2026, 10, 1)),
        updatedAt: Value(DateTime.utc(2026, 10, 1)),
        transcriptSource: const Value(1),
        transcriptSrt: const Value('1\n00:00:00,000 --> 00:00:01,000\nhi\n'),
        transcriptLanguage: const Value('en'),
        sentenceCount: const Value(1),
        wordCount: const Value(1),
      ),
    );
    await database.audioItemDao.upsert(
      AudioItemsCompanion(
        id: const Value('legacy-device'),
        name: const Value('Device transcript'),
        addedDate: Value(DateTime.utc(2026, 10, 1)),
        updatedAt: Value(DateTime.utc(2026, 10, 1)),
        transcriptSource: const Value(2),
      ),
    );
    await database.close();

    final raw = sqlite.sqlite3.open(file.path);
    try {
      raw.execute('ALTER TABLE audio_items DROP COLUMN transcript_word_timing_source');
      raw.execute('PRAGMA user_version = 61');
    } finally {
      raw.dispose();
    }

    database = AppDatabase(NativeDatabase(file));
    final ai = await database.audioItemDao.getById('legacy-ai');
    final device = await database.audioItemDao.getById('legacy-device');

    expect(ai?.transcriptSource, 1);
    expect(ai?.transcriptLanguage, 'en');
    expect(ai?.transcriptSrt, contains('hi'));
    expect(ai?.transcriptWordTimingSource, isNull);
    expect(device?.transcriptSource, 2);
    expect(device?.transcriptWordTimingSource, isNull);
    await database.close();
  });
}
