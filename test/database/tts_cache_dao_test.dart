import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:loop_back/database/app_database.dart';

/// 创建内存数据库用于测试
AppDatabase _createTestDb() {
  return AppDatabase(
    NativeDatabase.memory(
      setup: (db) {
        db.execute('PRAGMA foreign_keys = ON');
      },
    ),
  );
}

/// 便捷 upsert，填默认元数据。
Future<void> _put(
  AppDatabase db,
  String key, {
  String filePath = '/tmp/a.wav',
  int fileSize = 100,
  DateTime? expiresAt,
  bool isPinned = false,
}) {
  return db.ttsCacheDao.upsert(
    cacheKey: key,
    textHash: 'hash_$key',
    sourceText: 'text_$key',
    engine: 'platform',
    voice: 'en-US',
    languageCode: 'en-US',
    speed: 0.45,
    format: 'wav',
    filePath: filePath,
    fileSize: fileSize,
    expiresAt: expiresAt,
    isPinned: isPinned,
  );
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = _createTestDb();
  });

  tearDown(() async {
    await db.close();
  });

  group('TtsCacheDao', () {
    test('upsert 后 getByKey 返回条目', () async {
      await _put(db, 'k1', filePath: '/tmp/k1.wav');
      final row = await db.ttsCacheDao.getByKey('k1');
      expect(row, isNotNull);
      expect(row!.filePath, '/tmp/k1.wav');
      expect(row.engine, 'platform');
      expect(row.voice, 'en-US');
    });

    test('getByKey 未命中返回 null', () async {
      expect(await db.ttsCacheDao.getByKey('nope'), isNull);
    });

    test('upsert 相同 key 更新 filePath/fileSize', () async {
      await _put(db, 'k1', filePath: '/old.wav', fileSize: 1);
      await _put(db, 'k1', filePath: '/new.wav', fileSize: 2);
      final row = await db.ttsCacheDao.getByKey('k1');
      expect(row!.filePath, '/new.wav');
      expect(row.fileSize, 2);
    });

    test('getByKey 更新 lastAccessedAt', () async {
      await _put(db, 'k1');
      final pastEpoch =
          DateTime.now()
              .subtract(const Duration(days: 10))
              .millisecondsSinceEpoch ~/
          1000;
      await db.customStatement(
        "UPDATE tts_cache SET last_accessed_at = $pastEpoch WHERE cache_key = 'k1'",
      );
      await db.ttsCacheDao.getByKey('k1');
      // 读取后 lastAccessedAt 应被刷新到现在 → 不在 LRU 队首附近的很久之前
      final lru = await db.ttsCacheDao.unpinnedByLruAsc();
      expect(
        lru.first.lastAccessedAt.isAfter(
          DateTime.now().subtract(const Duration(days: 1)),
        ),
        isTrue,
      );
    });

    test('getByKey 带 slideTtl 续期 expiresAt（滑动过期）', () async {
      final soon = DateTime.now().add(const Duration(hours: 1));
      await _put(db, 'k1', expiresAt: soon);
      await db.ttsCacheDao.getByKey('k1', slideTtl: const Duration(days: 10));
      final row = await db.ttsCacheDao.getByKey('k1');
      // 过期时间应被推到接近 now+10天，远晚于原本的 1 小时后
      expect(
        row!.expiresAt!.isAfter(DateTime.now().add(const Duration(days: 9))),
        isTrue,
      );
    });

    test('getByKey 不传 slideTtl 时不动 expiresAt', () async {
      final soon = DateTime.now().add(const Duration(hours: 1));
      await _put(db, 'k1', expiresAt: soon);
      await db.ttsCacheDao.getByKey('k1');
      final row = await db.ttsCacheDao.getByKey('k1');
      // 仍在 2 小时内，未被续期
      expect(
        row!.expiresAt!.isBefore(DateTime.now().add(const Duration(hours: 2))),
        isTrue,
      );
    });

    test('getByKey 对永久条目（expiresAt=null）即便带 slideTtl 也不续期', () async {
      await _put(db, 'perm', expiresAt: null);
      await db.ttsCacheDao.getByKey('perm', slideTtl: const Duration(days: 10));
      final row = await db.ttsCacheDao.getByKey('perm');
      expect(row!.expiresAt, isNull);
    });

    test('expiredEntries 仅返回已过期且未 pin 的条目', () async {
      final past = DateTime.now().subtract(const Duration(days: 1));
      final future = DateTime.now().add(const Duration(days: 1));
      await _put(db, 'expired', expiresAt: past);
      await _put(db, 'fresh', expiresAt: future);
      await _put(db, 'noexpiry', expiresAt: null);
      await _put(db, 'pinned_expired', expiresAt: past, isPinned: true);

      final expired = await db.ttsCacheDao.expiredEntries(DateTime.now());
      expect(expired.map((e) => e.cacheKey), ['expired']);
    });

    test('totalSize 累加未删除条目', () async {
      await _put(db, 'a', fileSize: 100);
      await _put(db, 'b', fileSize: 250);
      expect(await db.ttsCacheDao.totalSize(), 350);
    });

    test('unpinnedByLruAsc 按最后访问时间升序、排除 pin', () async {
      await _put(db, 'old', isPinned: false);
      await _put(db, 'mid', isPinned: false);
      await _put(db, 'pin', isPinned: true);
      final oldEpoch =
          DateTime.now()
              .subtract(const Duration(days: 5))
              .millisecondsSinceEpoch ~/
          1000;
      await db.customStatement(
        "UPDATE tts_cache SET last_accessed_at = $oldEpoch WHERE cache_key = 'old'",
      );
      final lru = await db.ttsCacheDao.unpinnedByLruAsc();
      expect(lru.map((e) => e.cacheKey), ['old', 'mid']);
    });

    test('deleteByKey 删除单条', () async {
      await _put(db, 'k1');
      expect(await db.ttsCacheDao.deleteByKey('k1'), 1);
      expect(await db.ttsCacheDao.getByKey('k1'), isNull);
    });

    test('deleteAll 清空全部', () async {
      await _put(db, 'a');
      await _put(db, 'pin', isPinned: true);
      await db.ttsCacheDao.deleteAll();
      expect(await db.ttsCacheDao.totalSize(), 0);
    });
  });
}
