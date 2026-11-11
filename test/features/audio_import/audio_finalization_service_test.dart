import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:loop_back/features/audio_import/audio_finalization_service.dart';
import 'package:loop_back/features/audio_import/audio_import_cancel.dart';
import 'package:loop_back/features/audio_import/audio_import_models.dart';
import 'package:loop_back/features/audio_import/audio_transcode_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 转码桩：成功时把内容写到指定 output（标记已转码字节），失败时返回 false。
class _FakeTranscodeService extends AudioTranscodeService {
  _FakeTranscodeService({required this.shouldSucceed});

  final bool shouldSucceed;

  @override
  Future<bool> transcodeToFile({
    required File source,
    required File output,
  }) async {
    if (!shouldSucceed) return false;
    await output.parent.create(recursive: true);
    // 写入与源不同的字节，模拟转码后内容变化。
    await output.writeAsBytes([0xAA, ...await source.readAsBytes()]);
    return true;
  }
}

void main() {
  group('AudioFinalizationService.finalize（导入不转码）', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('audio_finalize_test_');
      final importDir = Directory(p.join(tmpDir.path, 'tmp', 'audio_import'));
      await importDir.create(recursive: true);
    });

    tearDown(() async {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });

    Future<String> writeTemp(String name, List<int> bytes) async {
      final file = File(p.join(tmpDir.path, 'tmp', 'audio_import', name));
      await file.writeAsBytes(bytes);
      return p.join('tmp', 'audio_import', name);
    }

    test('保留原始格式与扩展名，按原始指纹落盘，sha==originalSha', () async {
      final service = AudioFinalizationService(
        computeSha256: (_) async => 'sha-original',
      );
      final temp = await writeTemp('a.mp3', [1, 2, 3]);

      final result = await service.finalize(
        dataDir: tmpDir,
        tempRelativePath: temp,
        targetSubdir: p.join('audios', 'imported'),
      );

      expect(
        result.relativePath,
        p.join('audios', 'imported', 'sha-original.mp3'),
      );
      expect(result.sha256, 'sha-original');
      expect(result.originalSha256, 'sha-original');
      expect(result.created, isTrue);
      // 落盘文件即原始字节，未经转码。
      expect(
        await File(p.join(tmpDir.path, result.relativePath)).readAsBytes(),
        [1, 2, 3],
      );
      // 临时目录已清理。
      expect(
        await Directory(
          p.join(tmpDir.path, 'tmp', 'audio_import'),
        ).list().toList(),
        isEmpty,
      );
    });

    test('同指纹文件已存在：复用现有文件，不覆盖内容且标记 created=false', () async {
      final existing = File(
        p.join(tmpDir.path, 'audios', 'imported', 'sha-original.mp3'),
      );
      await existing.create(recursive: true);
      await existing.writeAsBytes([9, 9, 9]);

      final service = AudioFinalizationService(
        computeSha256: (_) async => 'sha-original',
      );
      final temp = await writeTemp('b.mp3', [1, 2, 3]);

      final result = await service.finalize(
        dataDir: tmpDir,
        tempRelativePath: temp,
        targetSubdir: p.join('audios', 'imported'),
      );

      expect(result.created, isFalse);
      expect(await existing.readAsBytes(), [9, 9, 9]);
      expect(
        await Directory(
          p.join(tmpDir.path, 'tmp', 'audio_import'),
        ).list().toList(),
        isEmpty,
      );
    });

    test('指纹计算期间取消会终止处理并清理临时文件', () async {
      final cancelToken = CancelToken();
      final fingerprintStarted = Completer<void>();
      final service = AudioFinalizationService(
        computeSha256WithCancellation: (_, {CancelToken? cancelToken}) async {
          fingerprintStarted.complete();
          final activeToken = cancelToken;
          if (activeToken == null) throw StateError('Expected cancel token');
          await activeToken.whenCancel;
          activeToken.throwIfCanceled();
          return 'unreachable';
        },
      );
      final temp = await writeTemp('cancel.mp3', [1, 2, 3]);
      final finalization = service.finalize(
        dataDir: tmpDir,
        tempRelativePath: temp,
        targetSubdir: p.join('audios', 'imported'),
        cancelToken: cancelToken,
      );

      await fingerprintStarted.future;
      cancelToken.cancel('user-cancelled');

      await expectLater(finalization, throwsA(isA<DioException>()));
      expect(await File(p.join(tmpDir.path, temp)).exists(), isFalse);
      final importDir = Directory(p.join(tmpDir.path, 'audios', 'imported'));
      expect(
        !await importDir.exists() || (await importDir.list().toList()).isEmpty,
        isTrue,
      );
    });
  });

  group('AudioFinalizationService.transcodeExisting（转录后转码）', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('audio_transcode_test_');
    });

    tearDown(() async {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });

    /// 在 audios/imported 下写一个原始音频，返回其相对路径。
    Future<String> writeOriginal(String name, List<int> bytes) async {
      final rel = p.join('audios', 'imported', name);
      final file = File(p.join(tmpDir.path, rel));
      await file.create(recursive: true);
      await file.writeAsBytes(bytes);
      return rel;
    }

    test('转码成功：按转码后指纹落盘 m4a，源文件保留，临时无残留', () async {
      var calls = 0;
      final service = AudioFinalizationService(
        transcodeService: _FakeTranscodeService(shouldSucceed: true),
        computeSha256: (_) async {
          calls++;
          return 'sha-transcoded';
        },
      );
      final original = await writeOriginal('sha-original.mp3', [1, 2, 3]);

      final result = await service.transcodeExisting(
        dataDir: tmpDir,
        relativePath: original,
      );

      expect(
        result.relativePath,
        p.join('audios', 'imported', 'sha-transcoded.m4a'),
      );
      expect(result.sha256, 'sha-transcoded');
      expect(result.created, isTrue);
      expect(calls, 1);
      // m4a 已落盘。
      expect(
        await File(p.join(tmpDir.path, result.relativePath)).exists(),
        isTrue,
      );
      // 源原始文件未被删除（由调用方在 DB 更新后删除）。
      expect(await File(p.join(tmpDir.path, original)).exists(), isTrue);
      // 临时目录无残留。
      final importDir = Directory(p.join(tmpDir.path, 'tmp', 'audio_import'));
      expect(
        !await importDir.exists() || (await importDir.list().toList()).isEmpty,
        isTrue,
      );
    });

    test('转码失败：抛 AudioImportException，源文件保留，临时无残留', () async {
      final service = AudioFinalizationService(
        transcodeService: _FakeTranscodeService(shouldSucceed: false),
        computeSha256: (_) async => 'sha-transcoded',
      );
      final original = await writeOriginal('sha-original.mp3', [1, 2, 3]);

      await expectLater(
        service.transcodeExisting(dataDir: tmpDir, relativePath: original),
        throwsA(isA<AudioImportException>()),
      );
      expect(await File(p.join(tmpDir.path, original)).exists(), isTrue);
      final importDir = Directory(p.join(tmpDir.path, 'tmp', 'audio_import'));
      expect(
        !await importDir.exists() || (await importDir.list().toList()).isEmpty,
        isTrue,
      );
    });

    test('同指纹 m4a 已存在：复用现有文件，created=false，临时无残留', () async {
      final existing = File(
        p.join(tmpDir.path, 'audios', 'imported', 'sha-transcoded.m4a'),
      );
      await existing.create(recursive: true);
      await existing.writeAsBytes([7, 7, 7]);

      final service = AudioFinalizationService(
        transcodeService: _FakeTranscodeService(shouldSucceed: true),
        computeSha256: (_) async => 'sha-transcoded',
      );
      final original = await writeOriginal('sha-original.mp3', [1, 2, 3]);

      final result = await service.transcodeExisting(
        dataDir: tmpDir,
        relativePath: original,
      );

      expect(result.created, isFalse);
      expect(await existing.readAsBytes(), [7, 7, 7]);
      final importDir = Directory(p.join(tmpDir.path, 'tmp', 'audio_import'));
      expect(
        !await importDir.exists() || (await importDir.list().toList()).isEmpty,
        isTrue,
      );
    });
  });
}
