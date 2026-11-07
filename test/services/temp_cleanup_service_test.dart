import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:echo_loop/services/temp_cleanup_service.dart';
import 'package:echo_loop/utils/app_data_dir.dart';

/// 设置目录修改时间（Directory 无 setLastModifiedSync，借助系统 touch）
void setDirMtime(Directory dir, DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  final ts =
      '${time.year}${two(time.month)}${two(time.day)}'
      '${two(time.hour)}${two(time.minute)}';
  Process.runSync('touch', ['-m', '-t', ts, dir.path]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeDocsDir;
  late Directory fakeCacheDir;
  late Directory fakeTmpDir;
  late Directory fakeAppDataDir;

  setUp(() {
    // 创建模拟的沙盒结构：sandbox/Documents, sandbox/tmp, sandbox/Library/Caches
    final sandbox = Directory.systemTemp.createTempSync('cleanup_test_');
    fakeDocsDir = Directory('${sandbox.path}/Documents')..createSync();
    fakeTmpDir = Directory('${sandbox.path}/tmp')..createSync();
    fakeCacheDir = Directory('${sandbox.path}/Library/Caches')
      ..createSync(recursive: true);
    fakeAppDataDir = Directory('${sandbox.path}/Application Support')
      ..createSync(recursive: true);
    appDataDirectoryOverride = fakeAppDataDir;

    // Mock path_provider
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (call.method == 'getApplicationDocumentsDirectory') {
              return fakeDocsDir.path;
            }
            if (call.method == 'getTemporaryDirectory') {
              return fakeCacheDir.path;
            }
            return null;
          },
        );
  });

  tearDown(() {
    appDataDirectoryOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    // 清理整个模拟沙盒
    final sandbox = fakeDocsDir.parent;
    if (sandbox.existsSync()) {
      sandbox.deleteSync(recursive: true);
    }
  });

  test('清理旧社区下载半成品时保留已下载媒体和其它临时文件', () async {
    final unfinished = File(
      '${fakeAppDataDir.path}/tmp/community_media/download.part',
    );
    await unfinished.parent.create(recursive: true);
    await unfinished.writeAsString('partial');
    final media = File('${fakeAppDataDir.path}/audio.m4a');
    await media.writeAsString('downloaded');
    final other = File('${fakeAppDataDir.path}/tmp/keep.tmp');
    await other.writeAsString('keep');

    await cleanupCommunityDownloadTmp();
    await cleanupCommunityDownloadTmp();

    expect(await unfinished.parent.exists(), isFalse);
    expect(await media.readAsString(), 'downloaded');
    expect(await other.readAsString(), 'keep');
  });

  test('清理旧在线字幕分块临时音频时保留源媒体与其它临时文件', () async {
    final chunk = File(
      '${fakeAppDataDir.path}/tmp/online_subtitle/run-1/chunk_0.wav',
    );
    await chunk.parent.create(recursive: true);
    await chunk.writeAsBytes(List.filled(64, 0));
    final media = File('${fakeAppDataDir.path}/audio.m4a');
    await media.writeAsString('source');

    await cleanupOnlineSubtitleTmp();

    expect(await chunk.parent.parent.exists(), isFalse);
    expect(await media.readAsString(), 'source');
  });

  group('cleanupRecordingTempFiles', () {
    test('删除 tmp/ 中的旧文件', () async {
      final oldFile = File('${fakeTmpDir.path}/old.caf');
      oldFile.writeAsBytesSync(List.filled(1000, 0));
      // 将修改时间设为 2 分钟前
      oldFile.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 2)),
      );

      final result = await cleanupRecordingTempFiles();

      expect(result.freedBytes, 1000);
      expect(oldFile.existsSync(), false);
    });

    test('跳过 tmp/ 中不足 minAge 的文件', () async {
      final newFile = File('${fakeTmpDir.path}/new.caf');
      newFile.writeAsBytesSync(List.filled(500, 0));
      // 刚创建的文件，不足 60 秒

      final result = await cleanupRecordingTempFiles();

      expect(result.freedBytes, 0);
      expect(newFile.existsSync(), true);
    });

    test('不清理 Library/Caches', () async {
      final cacheFile = File('${fakeCacheDir.path}/cached.dat');
      cacheFile.writeAsBytesSync(List.filled(2000, 0));
      cacheFile.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 5)),
      );

      await cleanupRecordingTempFiles();

      expect(cacheFile.existsSync(), true);
    });

    test('tmp/ 不存在时返回 0', () async {
      fakeTmpDir.deleteSync(recursive: true);

      final result = await cleanupRecordingTempFiles();

      expect(result.freedBytes, 0);
    });
  });

  group('cleanupAllTempFiles', () {
    test('清理备份流程遗留的最终备份文件', () async {
      final backup = File(
        '${fakeCacheDir.path}/echoloop_backup_20260713.elbak',
      );
      await backup.writeAsBytes(List<int>.filled(32, 1));

      final result = await cleanupAllTempFiles();

      expect(await backup.exists(), isFalse);
      expect(result.freedBytes, greaterThanOrEqualTo(32));
    });

    test('tmp/ 全量清理（任意名字文件都删）', () async {
      final tmpFile = File('${fakeTmpDir.path}/rec.caf');
      tmpFile.writeAsBytesSync(List.filled(1000, 0));

      final result = await cleanupAllTempFiles();

      expect(result.freedBytes, greaterThanOrEqualTo(1000));
      expect(tmpFile.existsSync(), false);
    });

    test('Library/Caches 只删 app 自建导出/导入临时目录', () async {
      final exportDir = Directory('${fakeCacheDir.path}/echoloop_export_123')
        ..createSync();
      File('${exportDir.path}/data.zip').writeAsBytesSync(List.filled(5000, 0));
      final importDir = Directory('${fakeCacheDir.path}/echoloop_import_9')
        ..createSync();
      File('${importDir.path}/x.bin').writeAsBytesSync(List.filled(100, 0));
      final audioExportDir = Directory('${fakeCacheDir.path}/audio_export_7')
        ..createSync();
      File(
        '${audioExportDir.path}/a.m4a',
      ).writeAsBytesSync(List.filled(200, 0));

      await cleanupAllTempFiles();

      expect(exportDir.existsSync(), false);
      expect(importDir.existsSync(), false);
      expect(audioExportDir.existsSync(), false);
    });

    test('Library/Caches 删除 pdf_export_ 临时目录', () async {
      final pdfDir = Directory('${fakeCacheDir.path}/pdf_export_123')
        ..createSync();
      File('${pdfDir.path}/a.pdf').writeAsBytesSync(List.filled(800, 0));

      await cleanupAllTempFiles();

      expect(pdfDir.existsSync(), false);
    });

    test('Library/Caches 删除 log_export_ 临时目录', () async {
      final logDir = Directory('${fakeCacheDir.path}/log_export_123')
        ..createSync();
      File('${logDir.path}/app.log').writeAsBytesSync(List.filled(300, 0));

      await cleanupAllTempFiles();

      expect(logDir.existsSync(), false);
    });

    test('Library/Caches 保护系统 URLCache 与框架缓存', () async {
      // 系统 URLCache：<bundleId>/Cache.db* 及散落的 Cache.db 文件
      final cacheDbFile = File('${fakeCacheDir.path}/Cache.db');
      cacheDbFile.writeAsBytesSync(List.filled(1000, 0));
      final urlCacheDir = Directory('${fakeCacheDir.path}/top.echo-loop.dev')
        ..createSync();
      File(
        '${urlCacheDir.path}/Cache.db',
      ).writeAsBytesSync(List.filled(2000, 0));
      File(
        '${urlCacheDir.path}/Cache.db-wal',
      ).writeAsBytesSync(List.filled(500, 0));
      // 网络图片缓存（由 flutter_cache_manager API 单独清，不在文件扫描范围）
      final imageCacheDir = Directory('${fakeCacheDir.path}/app_network_images')
        ..createSync();
      File(
        '${imageCacheDir.path}/img.bin',
      ).writeAsBytesSync(List.filled(300, 0));
      // 随机框架缓存
      final otherCache = File('${fakeCacheDir.path}/cached.dat');
      otherCache.writeAsBytesSync(List.filled(400, 0));

      await cleanupAllTempFiles();

      expect(cacheDbFile.existsSync(), true);
      expect(urlCacheDir.existsSync(), true);
      expect(imageCacheDir.existsSync(), true);
      expect(otherCache.existsSync(), true);
    });
  });

  group('cleanupStalePdfExportTemp', () {
    test('删除超过 minAge 的 pdf_export_ 目录', () async {
      final staleDir = Directory('${fakeCacheDir.path}/pdf_export_1')
        ..createSync();
      File('${staleDir.path}/a.pdf').writeAsBytesSync(List.filled(1000, 0));
      setDirMtime(staleDir, DateTime.now().subtract(const Duration(days: 2)));

      final result = await cleanupStalePdfExportTemp();

      expect(result.freedBytes, 1000);
      expect(staleDir.existsSync(), false);
    });

    test('保留不足 minAge 的 pdf_export_ 目录（可能正在 AirDrop）', () async {
      final freshDir = Directory('${fakeCacheDir.path}/pdf_export_2')
        ..createSync();
      File('${freshDir.path}/b.pdf').writeAsBytesSync(List.filled(500, 0));

      final result = await cleanupStalePdfExportTemp();

      expect(result.freedBytes, 0);
      expect(freshDir.existsSync(), true);
    });

    test('删除旧 log_export_ 目录并保留其他前缀与系统缓存', () async {
      final logDir = Directory('${fakeCacheDir.path}/log_export_1')
        ..createSync();
      File('${logDir.path}/app.log').writeAsBytesSync(List.filled(300, 0));
      setDirMtime(logDir, DateTime.now().subtract(const Duration(days: 3)));
      final audioDir = Directory('${fakeCacheDir.path}/audio_export_7')
        ..createSync();
      File('${audioDir.path}/a.m4a').writeAsBytesSync(List.filled(200, 0));
      setDirMtime(audioDir, DateTime.now().subtract(const Duration(days: 3)));
      final cacheDbFile = File('${fakeCacheDir.path}/Cache.db');
      cacheDbFile.writeAsBytesSync(List.filled(1000, 0));
      cacheDbFile.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 3)),
      );

      await cleanupStalePdfExportTemp();

      expect(logDir.existsSync(), false);
      expect(audioDir.existsSync(), true);
      expect(cacheDbFile.existsSync(), true);
    });
  });
}
