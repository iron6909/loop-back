import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop_back/services/orphan_file_cleanup_service.dart';
import 'package:loop_back/utils/app_data_dir.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDir;

  /// 在 [dataDir] 下按相对路径写入指定字节数的文件，自动建父目录。
  File writeFile(String relPath, int bytes) {
    final file = File('${dataDir.path}/$relPath');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List.filled(bytes, 0));
    return file;
  }

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('orphan_test_');
    appDataDirectoryOverride = dataDir;
  });

  tearDown(() {
    appDataDirectoryOverride = null;
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  group('cleanupOrphanMediaFiles', () {
    test('删除孤儿音频/字幕，保留被引用文件', () async {
      final referenced = writeFile('audios/imported/keep.mp3', 1000);
      final referencedSrt = writeFile('transcripts/keep.srt', 200);
      final orphanAudio = writeFile('audios/official/orphan.m4a', 500);
      final orphanSrt = writeFile('transcripts/orphan.srt', 300);

      final result = await cleanupOrphanMediaFiles(
        referencedRelPaths: {
          'audios/imported/keep.mp3',
          'transcripts/keep.srt',
        },
      );

      expect(result.freedBytes, 800);
      expect(referenced.existsSync(), true);
      expect(referencedSrt.existsSync(), true);
      expect(orphanAudio.existsSync(), false);
      expect(orphanSrt.existsSync(), false);
    });

    test('引用集合为空时删除全部媒体文件', () async {
      final a = writeFile('audios/imported/a.mp3', 100);
      final b = writeFile('audios/official/b.m4a', 100);

      final result = await cleanupOrphanMediaFiles(referencedRelPaths: {});

      expect(result.freedBytes, 200);
      expect(a.existsSync(), false);
      expect(b.existsSync(), false);
    });

    test('目录不存在时返回 0', () async {
      final result = await cleanupOrphanMediaFiles(referencedRelPaths: {});
      expect(result.freedBytes, 0);
    });

    test('清扫 audios/ 根目录的遗留孤儿，保留被引用的根目录文件', () async {
      // 旧版本直接存于 audios/ 根、可读文件名（如内置示例与早期导入）
      final referenced = writeFile('audios/Example - Kept.m4a', 400);
      final orphan = writeFile('audios/Legacy - Orphan.m4a', 600);

      final result = await cleanupOrphanMediaFiles(
        referencedRelPaths: {'audios/Example - Kept.m4a'},
      );

      expect(result.freedBytes, 600);
      expect(referenced.existsSync(), true);
      expect(orphan.existsSync(), false);
    });

    test('不触碰 waveforms 目录', () async {
      final wave = writeFile('waveforms/x.wave', 999);

      await cleanupOrphanMediaFiles(referencedRelPaths: {});

      expect(wave.existsSync(), true);
    });
  });

  group('cleanupAllWaveforms', () {
    test('全量删除波形缓存', () async {
      final w1 = writeFile('waveforms/a.wave', 1000);
      final w2 = writeFile('waveforms/b.wave', 2000);

      final result = await cleanupAllWaveforms();

      expect(result.freedBytes, 3000);
      expect(w1.existsSync(), false);
      expect(w2.existsSync(), false);
    });

    test('目录不存在时返回 0', () async {
      final result = await cleanupAllWaveforms();
      expect(result.freedBytes, 0);
    });
  });
}
