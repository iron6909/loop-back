import 'dart:io';
import 'dart:async';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:echo_loop/services/asr/asr_model_catalog.dart';
import 'package:echo_loop/services/pronunciation/pronunciation_library_manager.dart';
import 'package:echo_loop/services/pronunciation/pronunciation_catalog.dart';
import 'package:echo_loop/services/reliable_http_downloader.dart';

class _BytesDownloader implements ReliableHttpDownloader {
  _BytesDownloader(this.bytes);
  final List<int> bytes;
  final calls = <({Uri uri, bool allowResume, String savePath})>[];

  @override
  Future<ReliableDownloadResult> download({
    required Uri uri,
    required String savePath,
    Map<String, String> headers = const {},
    int? expectedSize,
    String? identityKey,
    bool allowResume = true,
    cancelToken,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    calls.add((uri: uri, allowResume: allowResume, savePath: savePath));
    final part = File('$savePath.part');
    if (part.existsSync()) await part.delete();
    final meta = File('$savePath.part.meta.json');
    if (meta.existsSync()) await meta.delete();
    await File(savePath).writeAsBytes(bytes);
    onProgress?.call(bytes.length, bytes.length);
    return ReliableDownloadResult(
      savePath: savePath,
      bytesWritten: bytes.length,
      resumed: false,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('catalog 包含当前发音包下载规格', () {
    expect(pronunciationSpec.resourceId, 'pronunciation-v2');
    expect(pronunciationSpec.estimatedDownloadBytes, 41379389);
    expect(pronunciationSpec.resource.repository, 'banko3/loop-back');
    expect(
      pronunciationSpec.resource.revision,
      '3b3a5bef53a1c2c86f72117a8ce149554122baac',
    );
    expect(pronunciationSpec.archiveFileName, 'pronunciation-v2.zip');
    expect(
      pronunciationSpec.archiveSha256,
      'db1bf8c8ec953f48ed05e22f8254cd8385f3c26f0acb630f73aedf14bbb6a1ca',
    );
  });

  test('公开源解析：主源与镜像只换域名，数据集路径与摘要相同', () {
    final upstream = pronunciationSpec.fileUri(AsrDownloadSource.huggingFace);
    final mirror = pronunciationSpec.fileUri(
      AsrDownloadSource.huggingFaceMirror,
    );
    expect(upstream.host, 'huggingface.co');
    expect(mirror.host, 'hf-mirror.com');
    expect(
      upstream.path,
      '/datasets/banko3/loop-back/resolve/'
      '3b3a5bef53a1c2c86f72117a8ce149554122baac/pronunciation-v2.zip',
    );
    expect(mirror.path, upstream.path);
  });
  late Directory support;
  late Directory source;

  setUp(() {
    support = Directory.systemTemp.createTempSync('pronunciation_support_');
    source = Directory.systemTemp.createTempSync('pronunciation_source_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? support.path
              : null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    support.deleteSync(recursive: true);
    source.deleteSync(recursive: true);
  });

  test(
    'valid archive installs database and referenced opus atomically',
    () async {
      final zip = _validArchive(source);
      final digest = sha256.convert(zip).toString();
      final downloader = _BytesDownloader(zip);
      final manager = PronunciationLibraryManager.withDownloader(
        downloader,
        sha256: digest,
      );
      Directory(
        p.join(support.path, 'pronunciation', 'v1'),
      ).createSync(recursive: true);

      final paths = await manager.downloadAndInstall();

      expect(File(paths.database).existsSync(), isTrue);
      expect(
        File(p.join(paths.audioDirectory, 'read_us.opus')).existsSync(),
        isTrue,
      );
      expect(await manager.installedPaths(), isNotNull);
      expect(
        Directory(p.join(support.path, 'pronunciation', 'v1')).existsSync(),
        isFalse,
      );
      expect(downloader.calls.single.allowResume, isTrue);
      expect(downloader.calls.single.uri.host, 'huggingface.co');
      expect(
        downloader.calls.single.uri.path,
        '/datasets/banko3/loop-back/resolve/'
        '3b3a5bef53a1c2c86f72117a8ce149554122baac/pronunciation-v2.zip',
      );
      manager.dispose();
    },
  );

  test('选择镜像源时下载地址换为 hf-mirror.com，路径与身份不变', () async {
    final zip = _validArchive(source);
    final downloader = _BytesDownloader(zip);
    final manager = PronunciationLibraryManager.withDownloader(
      downloader,
      sha256: sha256.convert(zip).toString(),
    );

    await manager.downloadAndInstall(
      source: AsrDownloadSource.huggingFaceMirror,
    );

    expect(downloader.calls.single.uri.host, 'hf-mirror.com');
    expect(
      downloader.calls.single.uri.path,
      '/datasets/banko3/loop-back/resolve/'
      '3b3a5bef53a1c2c86f72117a8ce149554122baac/pronunciation-v2.zip',
    );
    manager.dispose();
  });

  test('install isolate does not capture the installing callback', () async {
    final zip = _validArchive(source);
    final manager = PronunciationLibraryManager.withDownloader(
      _BytesDownloader(zip),
      sha256: sha256.convert(zip).toString(),
    );
    final installingEvents = StreamController<void>();
    var installing = false;
    installingEvents.stream.listen((_) => installing = true);

    final paths = await manager.downloadAndInstall(
      onInstalling: () => installingEvents.add(null),
    );
    await installingEvents.close();

    expect(installing, isTrue);
    expect(File(paths.database).existsSync(), isTrue);
    manager.dispose();
  });

  test(
    'archive path traversal is rejected and leaves no installed version',
    () async {
      final archive = Archive()
        ..addFile(ArchiveFile('../outside.opus', 1, [1]));
      final zip = ZipEncoder().encode(archive);
      final manager = PronunciationLibraryManager.withDownloader(
        _BytesDownloader(zip),
        sha256: sha256.convert(zip).toString(),
      );

      await expectLater(manager.downloadAndInstall(), throwsStateError);
      expect(await manager.installedPaths(), isNull);
      expect(File(p.join(support.path, 'outside.opus')).existsSync(), isFalse);
      manager.dispose();
    },
  );
}

List<int> _validArchive(Directory source) {
  final dbFile = File(p.join(source.path, 'pronunciation.sqlite'));
  final database = sqlite3.open(dbFile.path);
  database.execute('''
    CREATE TABLE pronunciation_audio (
      id INTEGER PRIMARY KEY,
      word TEXT NOT NULL COLLATE NOCASE,
      locale TEXT NOT NULL,
      audio_filename TEXT NOT NULL,
      "order" INTEGER NOT NULL
    )
  ''');
  database.execute(
    "INSERT INTO pronunciation_audio (word, locale, audio_filename, \"order\") "
    "VALUES ('read', 'us', 'read_us.opus', 1)",
  );
  database.dispose();
  final dbBytes = dbFile.readAsBytesSync();
  final archive = Archive()
    ..addFile(ArchiveFile('pronunciation.sqlite', dbBytes.length, dbBytes))
    ..addFile(ArchiveFile.directory('audio/'))
    ..addFile(ArchiveFile('audio/read_us.opus', 3, [1, 2, 3]));
  return ZipEncoder().encode(archive);
}
