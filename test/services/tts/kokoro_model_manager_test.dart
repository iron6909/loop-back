import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:echo_loop/services/asr/asr_model_catalog.dart';
import 'package:echo_loop/services/reliable_http_downloader.dart';
import 'package:echo_loop/services/tts/kokoro_model_catalog.dart';
import 'package:echo_loop/services/tts/kokoro_model_manager.dart';

/// 返回预置归档字节的 mock dio adapter（按 URL 末段文件名匹配）。
class _MockArchiveAdapter implements HttpClientAdapter {
  _MockArchiveAdapter(this.payload, {this.requestUris});

  /// 末段文件名 → 字节；命中返回 200，否则 404。
  final List<int> payload;
  final List<Uri>? requestUris;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestUris?.add(options.uri);
    if (!options.path.endsWith('.tar.gz')) {
      return ResponseBody(const Stream.empty(), 404, headers: {});
    }
    return ResponseBody(
      Stream.fromIterable([Uint8List.fromList(payload)]),
      200,
      headers: {
        'content-length': [payload.length.toString()],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 多归档 mock adapter：按 URL 末段文件名返回对应字节，供模型 + 依赖同测。
class _MultiArchiveAdapter implements HttpClientAdapter {
  _MultiArchiveAdapter(this.payloads, {this.requestUris});

  final Map<String, List<int>> payloads;
  final List<Uri>? requestUris;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestUris?.add(options.uri);
    final name = options.uri.pathSegments.isNotEmpty
        ? options.uri.pathSegments.last
        : '';
    final payload = payloads[name];
    if (payload == null) {
      return ResponseBody(const Stream.empty(), 404, headers: {});
    }
    return ResponseBody(
      Stream.fromIterable([Uint8List.fromList(payload)]),
      200,
      headers: {
        'content-length': [payload.length.toString()],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 对任何请求都返回 404 的 mock adapter，用于模拟归档下载的网络失败。
class _AlwaysNotFoundAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody(const Stream.empty(), 404, headers: {});

  @override
  void close({bool force = false}) {}
}

/// 支持 Range 的归档 mock，用于验证断点续传请求和完成后的残留清理。
class _RangeArchiveAdapter implements HttpClientAdapter {
  _RangeArchiveAdapter(this.payload);

  final List<int> payload;
  final requests = <Map<String, Object?>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(Map<String, Object?>.from(options.headers));
    final range = options.headers['Range']?.toString();
    if (range == null) {
      return ResponseBody(
        Stream.value(Uint8List.fromList(payload)),
        200,
        headers: {
          'content-length': [payload.length.toString()],
        },
      );
    }
    final start = int.parse(range.substring('bytes='.length, range.length - 1));
    final body = payload.sublist(start);
    return ResponseBody(
      Stream.value(Uint8List.fromList(body)),
      206,
      headers: {
        'content-length': [body.length.toString()],
        'content-range': [
          'bytes $start-${payload.length - 1}/${payload.length}',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 构造一个含关键文件的 tar.gz 字节（模型归档，含 `espeak-ng-data` 目录）。
List<int> _buildArchive({bool includeDataDir = true}) {
  final archive = Archive();
  archive.add(ArchiveFile('model.int8.onnx', 8, List<int>.filled(8, 1)));
  archive.add(ArchiveFile('voices.bin', 4, List<int>.filled(4, 2)));
  archive.add(ArchiveFile('tokens.txt', 3, List<int>.filled(3, 3)));
  if (includeDataDir) {
    // 目录由文件路径隐式建立。
    archive.add(
      ArchiveFile('espeak-ng-data/phondata', 6, List<int>.filled(6, 4)),
    );
  }
  final tar = TarEncoder().encodeBytes(archive);
  return GZipEncoder().encodeBytes(tar);
}

/// 构造 espeak-ng-data 归档字节（根级平铺，以 `phondata` 为完整性标记）。
List<int> _buildEspeakArchive() {
  final archive = Archive();
  archive.add(ArchiveFile('phondata', 6, List<int>.filled(6, 5)));
  archive.add(ArchiveFile('phontab', 5, List<int>.filled(5, 4)));
  final tar = TarEncoder().encodeBytes(archive);
  return GZipEncoder().encodeBytes(tar);
}

/// 构造测试用模型规格（`archiveFileName` 固定为 `test.tar.gz`）。
KokoroModelSpec _testSpec({required String sha}) {
  return KokoroModelSpec(
    variant: KokoroModelVariant.int8,
    id: 'test-model',
    modelFileName: 'model.int8.onnx',
    resource: AsrPublicResourceSpec(
      id: 'test-model',
      repository: 'example/models',
      revision: 'tts-models',
      layout: AsrPublicResourceLayout.githubReleaseAsset,
      license: 'Apache-2.0',
      files: [
        AsrResourceFile(name: 'test.tar.gz', sha256: sha, sizeBytes: 1024),
      ],
    ),
  );
}

KokoroModelManager _manager(
  Directory root,
  List<int> archive, {
  String? sha,
  List<Uri>? requestUris,
}) {
  final dio = Dio();
  dio.httpClientAdapter = _MockArchiveAdapter(
    archive,
    requestUris: requestUris,
  );
  return KokoroModelManager(
    dio: dio,
    baseUrlOverride: 'http://mock.local',
    spec: _testSpec(sha: sha ?? sha256.convert(archive).toString()),
    modelsRootResolver: () async => root.path,
  );
}

/// 构造 espeak-ng-data 独立资源规格及其注册表（供只补修复分支使用）。
Map<String, AsrPublicResourceSpec> _espeakRegistry(List<int> archive) {
  final resource = AsrPublicResourceSpec(
    id: 'espeak-ng-data',
    repository: 'example/models',
    revision: 'tts-models',
    layout: AsrPublicResourceLayout.githubReleaseAsset,
    license: 'GPL-3.0-or-later',
    files: [
      AsrResourceFile(
        name: 'espeak-ng-data.tar.gz',
        sha256: sha256.convert(archive).toString(),
        sizeBytes: archive.length,
      ),
    ],
  );
  return {'espeak-ng-data': resource};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kokoro-model-test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('下载 → 校验 → 解包：关键文件就位且 isModelDownloaded 为真', () async {
    final archive = _buildArchive();
    final requestedUris = <Uri>[];
    final manager = _manager(root, archive, requestUris: requestedUris);

    final progresses = <double>[];
    await manager.downloadModel(onProgress: (p) => progresses.add(p.progress));

    // 测试基地址覆盖下，归档 URL 末段即归档文件名。
    expect(requestedUris.single.host, 'mock.local');
    expect(requestedUris.single.path, '/test.tar.gz');
    expect(await manager.isModelDownloaded(), isTrue);
    final paths = await manager.kokoroConfigPaths();
    expect(File(paths.model).existsSync(), isTrue);
    expect(File(paths.voices).existsSync(), isTrue);
    expect(File(paths.tokens).existsSync(), isTrue);
    expect(Directory(paths.dataDir).existsSync(), isTrue);
    expect(p.basename(paths.dataDir), 'espeak-ng-data');
    // 进度应抵达 1.0。
    expect(progresses.last, 1.0);
  });

  test('公开源 URL 按 GitHub release asset 构造（不走 CDN 路由）', () async {
    final archive = _buildArchive();
    final requestedUris = <Uri>[];
    final dio = Dio();
    dio.httpClientAdapter = _MockArchiveAdapter(
      archive,
      requestUris: requestedUris,
    );
    final manager = KokoroModelManager(
      dio: dio,
      spec: KokoroModelSpec(
        variant: KokoroModelVariant.int8,
        id: 'kokoro-en-v0_19-int8',
        modelFileName: 'model.int8.onnx',
        resource: AsrPublicResourceSpec(
          id: 'kokoro-en-v0_19-int8',
          repository: 'iron6909/loop-back-models',
          revision: 'tts-models',
          layout: AsrPublicResourceLayout.githubReleaseAsset,
          license: 'Apache-2.0',
          files: [
            AsrResourceFile(
              name: 'kokoro-en-v0_19-int8-v2.tar.gz',
              sha256: sha256.convert(archive).toString(),
              sizeBytes: archive.length,
            ),
          ],
        ),
      ),
      modelsRootResolver: () async => root.path,
    );

    await manager.downloadModel();

    expect(
      requestedUris.single.toString(),
      'https://github.com/iron6909/loop-back-models/releases/download/tts-models/kokoro-en-v0_19-int8-v2.tar.gz',
    );
  });

  test('归档 SHA-256 不匹配 → 抛错且模型未安装', () async {
    final archive = _buildArchive();
    final manager = _manager(root, archive, sha: 'deadbeef');

    await expectLater(manager.downloadModel(), throwsA(isA<StateError>()));
    expect(await manager.isModelDownloaded(), isFalse);
    // 临时归档应被清理。
    final leftovers = root.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.tar.gz'),
    );
    expect(leftovers, isEmpty);
  });

  test('归档下载网络失败 → 抛结构化异常且不留 .part 残留', () async {
    final dio = Dio();
    dio.httpClientAdapter = _AlwaysNotFoundAdapter();
    final manager = KokoroModelManager(
      dio: dio,
      baseUrlOverride: 'http://mock.local',
      spec: _testSpec(sha: 'irrelevant'),
      modelsRootResolver: () async => root.path,
    );

    await expectLater(
      manager.downloadModel(),
      throwsA(
        isA<ReliableDownloadException>().having(
          (e) => e.kind,
          'kind',
          ReliableDownloadFailure.httpStatus,
        ),
      ),
    );
    final leftovers = root.listSync().whereType<File>();
    expect(leftovers, isEmpty);
  });

  test('预置 .part → 使用 Range 续传并在安装后清理残留', () async {
    final archive = _buildArchive();
    final sha = sha256.convert(archive).toString();
    final partialLength = archive.length ~/ 2;
    final partial = File(p.join(root.path, '_download_test-model.tar.gz.part'));
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(archive.sublist(0, partialLength));
    await File(
      '${partial.path}.meta.json',
    ).writeAsString('{"identityKey":"$sha","downloadedBytes":$partialLength}');
    final adapter = _RangeArchiveAdapter(archive);
    final dio = Dio()..httpClientAdapter = adapter;
    final manager = KokoroModelManager(
      dio: dio,
      baseUrlOverride: 'http://mock.local',
      spec: _testSpec(sha: sha),
      modelsRootResolver: () async => root.path,
    );

    await manager.downloadModel();

    expect(adapter.requests.single['Range'], 'bytes=$partialLength-');
    expect(await manager.isModelDownloaded(), isTrue);
    expect(partial.existsSync(), isFalse);
    expect(File('${partial.path}.meta.json').existsSync(), isFalse);
  });

  test('安装失败不会覆盖已有模型，staging 会清理', () async {
    final valid = _buildArchive();
    final manager = _manager(root, valid);
    await manager.downloadModel();
    final oldModel = File(p.join(await manager.modelDir(), 'model.int8.onnx'));
    final invalid = _buildArchive(includeDataDir: false);
    final invalidManager = _manager(
      root,
      invalid,
      sha: sha256.convert(invalid).toString(),
    );

    await expectLater(
      invalidManager.downloadModel(),
      throwsA(isA<StateError>()),
    );

    expect(oldModel.existsSync(), isTrue);
    expect(await manager.isModelDownloaded(), isTrue);
    expect(
      root.listSync().whereType<Directory>().where(
        (directory) => p.basename(directory.path).startsWith('_staging_'),
      ),
      isEmpty,
    );
  });

  test('deleteModel 清理续传归档、元数据和 staging', () async {
    final manager = _manager(root, _buildArchive());
    final archive = File(p.join(root.path, '_download_test-model.tar.gz'));
    final partial = File('${archive.path}.part');
    final meta = File('${partial.path}.meta.json');
    final staging = Directory(p.join(root.path, '_staging_test-model_old'));
    await staging.create(recursive: true);
    await archive.writeAsBytes([1]);
    await partial.writeAsBytes([1, 2]);
    await meta.writeAsString('{}');

    await manager.deleteModel();

    expect(archive.existsSync(), isFalse);
    expect(partial.existsSync(), isFalse);
    expect(meta.existsSync(), isFalse);
    expect(staging.existsSync(), isFalse);
  });

  test('解包后缺关键文件（无 espeak-ng-data）→ 抛错', () async {
    final archive = _buildArchive(includeDataDir: false);
    final manager = _manager(root, archive);

    await expectLater(manager.downloadModel(), throwsA(isA<StateError>()));
    expect(await manager.isModelDownloaded(), isFalse);
  });

  test('deleteModel 删除本地目录', () async {
    final archive = _buildArchive();
    final manager = _manager(root, archive);
    await manager.downloadModel();
    expect(await manager.isModelDownloaded(), isTrue);

    await manager.deleteModel();
    expect(await manager.isModelDownloaded(), isFalse);
    expect(await manager.modelLocalSize(), 0);
  });

  test('modelLocalSize 在下载后大于 0', () async {
    final archive = _buildArchive();
    final manager = _manager(root, archive);
    await manager.downloadModel();
    expect(await manager.modelLocalSize(), greaterThan(0));
  });

  test('首次安装只下模型归档，不产生顶层 espeak 目录', () async {
    final modelArchive = _buildArchive();
    final espeakArchive = _buildEspeakArchive();
    final requested = <Uri>[];
    final dio = Dio();
    dio.httpClientAdapter = _MultiArchiveAdapter(
      {
        'test.tar.gz': modelArchive,
        'espeak-ng-data.tar.gz': espeakArchive,
      },
      requestUris: requested,
    );
    final manager = KokoroModelManager(
      dio: dio,
      baseUrlOverride: 'http://mock.local',
      spec: _testSpec(sha: sha256.convert(modelArchive).toString()),
      resourceRegistryOverride: _espeakRegistry(espeakArchive),
      modelsRootResolver: () async => root.path,
    );

    await manager.downloadModel();

    expect(await manager.isModelDownloaded(), isTrue);
    expect(requested.map((u) => u.pathSegments.last).toList(), ['test.tar.gz']);
    // 模型归档自带 espeak-ng-data，不再在 tts-models 顶层安装独立目录。
    expect(
      Directory(p.join(root.path, 'espeak-ng-data')).existsSync(),
      isFalse,
    );
    final paths = await manager.kokoroConfigPaths();
    expect(File(p.join(paths.dataDir, 'phondata')).existsSync(), isTrue);
  });

  test('espeak 缺失时只下 espeak 归档且模型不重下', () async {
    final modelArchive = _buildArchive();
    final espeakArchive = _buildEspeakArchive();
    final requested = <Uri>[];
    final dio = Dio();
    dio.httpClientAdapter = _MultiArchiveAdapter(
      {
        'test.tar.gz': modelArchive,
        'espeak-ng-data.tar.gz': espeakArchive,
      },
      requestUris: requested,
    );
    final manager = KokoroModelManager(
      dio: dio,
      baseUrlOverride: 'http://mock.local',
      spec: _testSpec(sha: sha256.convert(modelArchive).toString()),
      resourceRegistryOverride: _espeakRegistry(espeakArchive),
      modelsRootResolver: () async => root.path,
    );

    await manager.downloadModel();
    requested.clear();

    // 删除模型目录内的 espeak-ng-data，模拟损坏安装。
    final dataDir = Directory(
      p.join(await manager.modelDir(), 'espeak-ng-data'),
    );
    await dataDir.delete(recursive: true);
    expect(await manager.isModelDownloaded(), isFalse);

    // 再下载：只补 espeak 归档，模型归档不重下，修复后即视为已下载。
    await manager.downloadModel();
    expect(
      requested.map((u) => u.pathSegments.last).toList(),
      ['espeak-ng-data.tar.gz'],
    );
    expect(await manager.isModelDownloaded(), isTrue);
    expect(File(p.join(dataDir.path, 'phondata')).existsSync(), isTrue);
  });

  test('espeak 修复失败 → 抛错且模型目录保留', () async {
    final modelArchive = _buildArchive();
    final espeakArchive = _buildEspeakArchive();
    final dio = Dio();
    dio.httpClientAdapter = _MultiArchiveAdapter({'test.tar.gz': modelArchive});
    final manager = KokoroModelManager(
      dio: dio,
      baseUrlOverride: 'http://mock.local',
      spec: _testSpec(sha: sha256.convert(modelArchive).toString()),
      resourceRegistryOverride: _espeakRegistry(espeakArchive),
      modelsRootResolver: () async => root.path,
    );
    await manager.downloadModel();
    final modelDir = await manager.modelDir();
    await Directory(
      p.join(modelDir, 'espeak-ng-data'),
    ).delete(recursive: true);

    // 坏 manager：espeak 资源 SHA 故意写错，只补分支校验失败。
    final badDio = Dio();
    badDio.httpClientAdapter = _MultiArchiveAdapter({
      'espeak-ng-data.tar.gz': espeakArchive,
    });
    final badManager = KokoroModelManager(
      dio: badDio,
      baseUrlOverride: 'http://mock.local',
      spec: _testSpec(sha: sha256.convert(modelArchive).toString()),
      resourceRegistryOverride: {
        'espeak-ng-data': AsrPublicResourceSpec(
          id: 'espeak-ng-data',
          repository: 'example/models',
          revision: 'tts-models',
          layout: AsrPublicResourceLayout.githubReleaseAsset,
          license: 'GPL-3.0-or-later',
          files: [
            AsrResourceFile(
              name: 'espeak-ng-data.tar.gz',
              sha256: 'deadbeef',
              sizeBytes: espeakArchive.length,
            ),
          ],
        ),
      },
      modelsRootResolver: () async => root.path,
    );

    await expectLater(badManager.downloadModel(), throwsA(isA<StateError>()));
    // 模型本体文件保留，espeak 仍未恢复 → 仍视为未下载（failed 由 provider 映射）。
    expect(File(p.join(modelDir, 'model.int8.onnx')).existsSync(), isTrue);
    expect(await badManager.isModelDownloaded(), isFalse);
  });
}
