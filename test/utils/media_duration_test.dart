import 'dart:io';

import 'package:loop_back/services/app_logger.dart';
import 'package:loop_back/utils/media_duration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('MediaDurationReader', () {
    late Directory tempDirectory;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'media_duration_reader_test_',
      );
    });

    tearDown(() async {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    test('音频和视频扩展名共用 media_kit 探测器', () async {
      final mediaPaths = <String>[];
      final traceIds = <String?>[];
      final reader = MediaDurationReader(
        resolveDataDirectory: () async => tempDirectory,
        mediaProbe: (filePath, {traceId}) async {
          mediaPaths.add(filePath);
          traceIds.add(traceId);
          return const Duration(seconds: 83);
        },
      );

      final mkvSeconds = await reader.read(
        'videos/lesson.MKV',
        traceId: 'mkv-trace',
      );
      final mp3Seconds = await reader.read(
        'audios/lesson.mp3',
        traceId: 'mp3-trace',
      );

      expect(mkvSeconds, 83);
      expect(mp3Seconds, 83);
      expect(mediaPaths, [
        path.join(tempDirectory.path, 'videos/lesson.MKV'),
        path.join(tempDirectory.path, 'audios/lesson.mp3'),
      ]);
      expect(traceIds, ['mkv-trace', 'mp3-trace']);
    });

    test('探测无结果时返回 0', () async {
      final reader = MediaDurationReader(
        resolveDataDirectory: () async => tempDirectory,
        mediaProbe: (_, {traceId}) async => null,
      );

      expect(await reader.read('videos/unsupported.mkv'), 0);
    });

    test('目录解析失败且没有 traceId 时仍记录脱敏错误', () async {
      AppLogger.instance.clear();
      final reader = MediaDurationReader(
        resolveDataDirectory: () async {
          throw const FileSystemException('directory unavailable');
        },
      );

      expect(await reader.read('audios/lesson.mp3'), 0);
      expect(
        AppLogger.instance.entries.any(
          (entry) =>
              entry.message.contains('event=probe_failed trace=none') &&
              entry.message.contains('phase=resolve_data_directory') &&
              entry.message.contains('errorType=FileSystemException') &&
              !entry.message.contains('directory unavailable'),
        ),
        isTrue,
      );
    });
  });
}
