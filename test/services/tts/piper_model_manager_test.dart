import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:loop_back/services/asr/asr_model_catalog.dart';
import 'package:loop_back/services/reliable_http_downloader.dart';
import 'package:loop_back/services/tts/piper_model_manager.dart';
import 'package:loop_back/services/tts/piper_model_catalog.dart';
import 'package:loop_back/services/tts/tts_engine.dart';
import 'package:loop_back/services/tts/tts_shared_resource_catalog.dart';

/// 按文件名返回预置字节的 mock adapter；未知文件返回 404。
class _MockResourceAdapter implements HttpClientAdapter {
  _MockResourceAdapter(this.byName, {this.requestUris});
  final Map<String, List<int>> byName;
  final List<Uri>? requestUris;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestUris?.add(options.uri);
    final name = options.path.split('/').last;
    final payload = byName[name];
    if (payload == null) {
      return ResponseBody(const Stream.empty(), 404, headers: {});
    }
    return ResponseBody(
      Stream.fromIterable([Uint8List.fromList(payload)]),
      200,
      headers: {'content-length': [payload.length.toString()]},
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 对任何请求都返回 404 的 mock adapter，用于模拟网络失败。
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
        headers: {'content-length': [payload.length.toString()]},
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

List<int> _gzipTar(Archive archive) {
  final tar = TarEncoder().encodeBytes(archive);
  return GZipEncoder().encodeBytes(tar);
}

/// 构造 GitHub 整包音色归档：`<id>.onnx` + `.onnx.json`（应被忽略）+ tokens +
/// espeak-ng-data/phondata。Piper 单说话人，无 voices.bin。
List<int> _buildArchive({
  String onnxName = 'en_US-ryan-medium.onnx',
  bool includeDataDir = true,
}) {
  final archive = Archive();
  archive.add(ArchiveFile(onnxName, 8, List<int>.filled(8, 1)));
  archive.add(ArchiveFile('$onnxName.json', 4, List<int>.filled(4, 9)));
  archive.add(ArchiveFile('tokens.txt', 3, List<int>.filled(3, 3)));
  if (includeDataDir) {
    archive.add(
      ArchiveFile('espeak-ng-data/phondata', 5, List<int>.filled(5, 4)),
    );
  }
  return _gzipTar(archive);
}

/// 构造共享 espeak-ng-data 归档（根级平铺，以 phondata 作为完整性标记）。
List<int> _buildEspeakArchive() {
  final archive = Archive();
  archive.add(ArchiveFile('phondata', 5, List<int>.filled(5, 6)));
  return _gzipTar(archive);
}

AsrPublicResourceSpec _githubSpec({
  required String id,
  required String archiveName,
  required String sha256,
  required int sizeBytes,
}) {
  return AsrPublicResourceSpec(
    id: id,
    repository: 'iron6909/loop-back-models',
    revision: 'tts-models',
    layout: AsrPublicResourceLayout.githubReleaseAsset,
    license: 'CC0',
    files: [AsrResourceFile(name: archiveName, sha256: sha256, sizeBytes: sizeBytes)],
    dependencies: const [ttsEspeakNgDataResourceId],
  );
}

AsrPublicResourceSpec _hfSpec({
  required String id,
  required String onnxName,
  required String onnxSha256,
  required int onnxSizeBytes,
  required String tokensSha256,
  required int tokensSizeBytes,
}) {
  return AsrPublicResourceSpec(
    id: id,
    repository: 'csukuangfj/vits-piper-$id',
    revision: 'test-commit',
    layout: AsrPublicResourceLayout.huggingFaceResolve,
    license: 'CC0',
    files: [
      AsrResourceFile(name: onnxName, sha256: onnxSha256, sizeBytes: onnxSizeBytes),
      AsrResourceFile(
        name: piperTokensFileName,
        sha256: tokensSha256,
        sizeBytes: tokensSizeBytes,
      ),
    ],
    dependencies: const [ttsEspeakNgDataResourceId],
  );
}

AsrPublicResourceSpec _espeakSpec(List<int> espeakArchive) {
  return AsrPublicResourceSpec(
    id: ttsEspeakNgDataResourceId,
    repository: 'iron6909/loop-back-models',
    revision: 'tts-models',
    layout: AsrPublicResourceLayout.githubReleaseAsset,
    license: 'GPL-3.0-or-later',
    files: [
      AsrResourceFile(
        name: ttsEspeakNgDataFileName,
        sha256: sha256.convert(espeakArchive).toString(),
        sizeBytes: espeakArchive.length,
      ),
    ],
  );
}

PiperModelManager _manager(
  Directory root,
  PiperVoice voice,
  List<int> archive, {
  List<Uri>? requestUris,
}) {
  final dio = Dio();
  dio.httpClientAdapter = _MockResourceAdapter(
    {voice.resource.files.single.name: archive},
    requestUris: requestUris,
  );
  return PiperModelManager(
    dio: dio,
    baseUrlOverride: 'http://mock.local',
    voice: voice,
    modelsRootResolver: () async => root.path,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('piper-model-test');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  PiperVoice githubVoice(List<int> archive) {
    return PiperVoice(
      id: 'en_US-ryan-medium',
      displayName: 'Ryan',
      accent: TtsAccent.us,
      isFemale: false,
      license: 'CC0',
      resource: _githubSpec(
        id: 'en_US-ryan-medium',
        archiveName: 'vits-piper-en_US-ryan-medium.tar.gz',
        sha256: sha256.convert(archive).toString(),
        sizeBytes: archive.length,
      ),
    );
  }

  test('下载 → 校验 → 解包：onnx/tokens/espeak-ng-data 就位，忽略 .onnx.json', () async {
    final archive = _buildArchive();
    final requestedUris = <Uri>[];
    final manager = _manager(
      root,
      githubVoice(archive),
      archive,
      requestUris: requestedUris,
    );

    final progresses = <double>[];
    await manager.downloadModel(onProgress: (p) => progresses.add(p.progress));

    expect(requestedUris.single.path, '/vits-piper-en_US-ryan-medium.tar.gz');
    expect(await manager.isModelDownloaded(), isTrue);
    final paths = await manager.piperConfigPaths();
    expect(p.basename(paths.model), 'en_US-ryan-medium.onnx');
    expect(File(paths.model).existsSync(), isTrue);
    expect(File(paths.tokens).existsSync(), isTrue);
    expect(p.basename(paths.dataDir), 'espeak-ng-data');
    expect(progresses.last, 1.0);
  });

  test('SHA-256 不匹配 → 抛错且模型未安装，临时归档已清理', () async {
    final archive = _buildArchive();
    final voice = PiperVoice(
      id: 'en_US-ryan-medium',
      displayName: 'Ryan',
      accent: TtsAccent.us,
      isFemale: false,
      license: 'CC0',
      resource: _githubSpec(
        id: 'en_US-ryan-medium',
        archiveName: 'vits-piper-en_US-ryan-medium.tar.gz',
        sha256: 'deadbeef',
        sizeBytes: archive.length,
      ),
    );
    final manager = _manager(root, voice, archive);

    await expectLater(manager.downloadModel(), throwsA(isA<StateError>()));
    expect(await manager.isModelDownloaded(), isFalse);
    final leftovers = root.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.tar.gz'),
    );
    expect(leftovers, isEmpty);
  });

  test('归档下载网络失败 → 抛结构化异常且不留 .part 残留', () async {
    final dio = Dio();
    dio.httpClientAdapter = _AlwaysNotFoundAdapter();
    final archive = _buildArchive();
    final manager = PiperModelManager(
      dio: dio,
      baseUrlOverride: 'http://mock.local',
      voice: githubVoice(archive),
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
    final partial = File(
      p.join(root.path, '_download_en_US-ryan-medium.tar.gz.part'),
    );
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(archive.sublist(0, partialLength));
    await File(
      '${partial.path}.meta.json',
    ).writeAsString('{"identityKey":"$sha","downloadedBytes":$partialLength}');
    final adapter = _RangeArchiveAdapter(archive);
    final dio = Dio()..httpClientAdapter = adapter;
    final manager = PiperModelManager(
      dio: dio,
      baseUrlOverride: 'http://mock.local',
      voice: githubVoice(archive),
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
    final manager = _manager(root, githubVoice(valid), valid);
    await manager.downloadModel();
    final oldModel = File(
      p.join(await manager.modelDir(), 'en_US-ryan-medium.onnx'),
    );
    final invalid = _buildArchive(includeDataDir: false);
    final invalidVoice = PiperVoice(
      id: 'en_US-ryan-medium',
      displayName: 'Ryan',
      accent: TtsAccent.us,
      isFemale: false,
      license: 'CC0',
      resource: _githubSpec(
        id: 'en_US-ryan-medium',
        archiveName: 'vits-piper-en_US-ryan-medium.tar.gz',
        sha256: sha256.convert(invalid).toString(),
        sizeBytes: invalid.length,
      ),
    );
    final invalidManager = _manager(root, invalidVoice, invalid);

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
    final manager = _manager(root, githubVoice(_buildArchive()), _buildArchive());
    final archive = File(
      p.join(root.path, '_download_en_US-ryan-medium.tar.gz'),
    );
    final partial = File('${archive.path}.part');
    final meta = File('${partial.path}.meta.json');
    final staging = Directory(
      p.join(root.path, '_staging_en_US-ryan-medium_old'),
    );
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

  test('解包后缺 espeak-ng-data → 抛错', () async {
    final archive = _buildArchive(includeDataDir: false);
    final voice = PiperVoice(
      id: 'en_US-ryan-medium',
      displayName: 'Ryan',
      accent: TtsAccent.us,
      isFemale: false,
      license: 'CC0',
      resource: _githubSpec(
        id: 'en_US-ryan-medium',
        archiveName: 'vits-piper-en_US-ryan-medium.tar.gz',
        sha256: sha256.convert(archive).toString(),
        sizeBytes: archive.length,
      ),
    );
    final manager = _manager(root, voice, archive);
    await expectLater(manager.downloadModel(), throwsA(isA<StateError>()));
    expect(await manager.isModelDownloaded(), isFalse);
  });

  test('deleteModel 删除本地目录；modelLocalSize 归零', () async {
    final manager = _manager(root, githubVoice(_buildArchive()), _buildArchive());
    await manager.downloadModel();
    expect(await manager.modelLocalSize(), greaterThan(0));
    await manager.deleteModel();
    expect(await manager.isModelDownloaded(), isFalse);
    expect(await manager.modelLocalSize(), 0);
  });

  test('HF 逐文件音色：onnx+tokens 逐文件安装并补共享 espeak-ng-data', () async {
    final onnx = List<int>.filled(16, 7);
    final tokens = List<int>.filled(6, 8);
    final espeak = _buildEspeakArchive();
    final voice = PiperVoice(
      id: 'en_US-amy-medium',
      displayName: 'Amy',
      accent: TtsAccent.us,
      isFemale: true,
      license: 'CC0',
      resource: _hfSpec(
        id: 'en_US-amy-medium',
        onnxName: 'en_US-amy-medium.onnx',
        onnxSha256: sha256.convert(onnx).toString(),
        onnxSizeBytes: onnx.length,
        tokensSha256: sha256.convert(tokens).toString(),
        tokensSizeBytes: tokens.length,
      ),
    );
    final dio = Dio();
    final requestedUris = <Uri>[];
    dio.httpClientAdapter = _MockResourceAdapter(
      {
        'en_US-amy-medium.onnx': onnx,
        piperTokensFileName: tokens,
        ttsEspeakNgDataFileName: espeak,
      },
      requestUris: requestedUris,
    );
    final manager = PiperModelManager(
      dio: dio,
      baseUrlOverride: 'http://mock.local',
      voice: voice,
      resourceRegistryOverride: {
        voice.id: voice.resource,
        ttsEspeakNgDataResourceId: _espeakSpec(espeak),
      },
      modelsRootResolver: () async => root.path,
    );

    await manager.downloadModel();

    expect(await manager.isModelDownloaded(), isTrue);
    final paths = await manager.piperConfigPaths();
    expect(p.basename(paths.model), 'en_US-amy-medium.onnx');
    expect(File(paths.tokens).existsSync(), isTrue);
    expect(File(p.join(paths.dataDir, 'phondata')).existsSync(), isTrue);
    expect(
      requestedUris.map((u) => u.path).toSet(),
      containsAll({
        '/en_US-amy-medium.onnx',
        '/tokens.txt',
        '/espeak-ng-data.tar.gz',
      }),
    );
  });

  test('HF 音色只补分支：onnx/tokens 齐全、espeak 缺失时只下 espeak', () async {
    final onnx = List<int>.filled(16, 7);
    final tokens = List<int>.filled(6, 8);
    final espeak = _buildEspeakArchive();
    final voice = PiperVoice(
      id: 'en_US-amy-medium',
      displayName: 'Amy',
      accent: TtsAccent.us,
      isFemale: true,
      license: 'CC0',
      resource: _hfSpec(
        id: 'en_US-amy-medium',
        onnxName: 'en_US-amy-medium.onnx',
        onnxSha256: sha256.convert(onnx).toString(),
        onnxSizeBytes: onnx.length,
        tokensSha256: sha256.convert(tokens).toString(),
        tokensSizeBytes: tokens.length,
      ),
    );
    // 先手工布置 onnx + tokens（模拟既有安装，缺 espeak）。
    final target = Directory(p.join(root.path, voice.id));
    await target.create(recursive: true);
    await File(p.join(target.path, 'en_US-amy-medium.onnx')).writeAsBytes(onnx);
    await File(p.join(target.path, 'tokens.txt')).writeAsBytes(tokens);

    final dio = Dio();
    final requestedUris = <Uri>[];
    dio.httpClientAdapter = _MockResourceAdapter(
      {ttsEspeakNgDataFileName: espeak},
      requestUris: requestedUris,
    );
    final manager = PiperModelManager(
      dio: dio,
      baseUrlOverride: 'http://mock.local',
      voice: voice,
      resourceRegistryOverride: {
        voice.id: voice.resource,
        ttsEspeakNgDataResourceId: _espeakSpec(espeak),
      },
      modelsRootResolver: () async => root.path,
    );

    await manager.downloadModel();

    expect(await manager.isModelDownloaded(), isTrue);
    expect(requestedUris.single.path, '/espeak-ng-data.tar.gz');
  });

  test('espeak 目录存在但 phondata 缺失 → 视为未下载且只补 espeak', () async {
    final modelArchive = _buildArchive();
    final espeakArchive = _buildEspeakArchive();
    final voice = githubVoice(modelArchive);
    final requestedUris = <Uri>[];
    final dio = Dio();
    dio.httpClientAdapter = _MockResourceAdapter(
      {
        voice.resource.files.single.name: modelArchive,
        ttsEspeakNgDataFileName: espeakArchive,
      },
      requestUris: requestedUris,
    );
    final manager = PiperModelManager(
      dio: dio,
      baseUrlOverride: 'http://mock.local',
      voice: voice,
      resourceRegistryOverride: {
        voice.id: voice.resource,
        ttsEspeakNgDataResourceId: _espeakSpec(espeakArchive),
      },
      modelsRootResolver: () async => root.path,
    );

    await manager.downloadModel();
    requestedUris.clear();

    // 仅删除 phondata（保留 espeak-ng-data 目录），模拟目录存在但核心文件缺失。
    final dataDir = Directory(
      p.join(await manager.modelDir(), piperDataDirectoryName),
    );
    await File(p.join(dataDir.path, 'phondata')).delete();
    expect(await manager.isModelDownloaded(), isFalse);

    // 再下载：只补 espeak 归档，模型归档不重下，修复后即视为已下载。
    await manager.downloadModel();
    expect(requestedUris.map((u) => u.path).toList(), ['/espeak-ng-data.tar.gz']);
    expect(await manager.isModelDownloaded(), isTrue);
    expect(File(p.join(dataDir.path, 'phondata')).existsSync(), isTrue);
  });
}
