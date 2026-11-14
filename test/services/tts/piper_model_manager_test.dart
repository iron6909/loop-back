import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:loop_back/services/asr/asr_model_catalog.dart';
import 'package:loop_back/services/reliable_http_downloader.dart';
import 'package:loop_back/services/tts/piper_model_catalog.dart';
import 'package:loop_back/services/tts/piper_model_manager.dart';
import 'package:loop_back/services/tts/tts_engine.dart' show TtsAccent;

/// 按 URL 末段文件名返回预置字节的 mock adapter（支持 Range 续传）。
class _MockFileAdapter implements HttpClientAdapter {
  _MockFileAdapter(this.payloads, {this.requestUris});

  /// 文件名 → 字节；未命中返回 404。
  final Map<String, List<int>> payloads;
  final List<Uri>? requestUris;
  final List<Map<String, Object?>> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(Map<String, Object?>.from(options.headers));
    requestUris?.add(options.uri);
    final name = options.uri.pathSegments.isEmpty
        ? ''
        : options.uri.pathSegments.last;
    final payload = payloads[name];
    if (payload == null) {
      return ResponseBody(const Stream.empty(), 404, headers: {});
    }
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
        'content-range': ['bytes $start-${payload.length - 1}/${payload.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 对任何请求都返回 404（模拟网络失败）。
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

/// 构造 espeak-ng-data 归档字节（根级平铺，以 `phondata` 为完整性标记）。
List<int> _buildEspeakArchive() {
  final archive = Archive();
  archive.add(ArchiveFile('phondata', 5, List<int>.filled(5, 6)));
  final tar = TarEncoder().encodeBytes(archive);
  return GZipEncoder().encodeBytes(tar);
}

/// 测试音色的模型文件（onnx + tokens.txt）。
const _testVoiceId = 'en_US-test-medium';
final Map<String, List<int>> _modelFiles = {
  '$_testVoiceId.onnx': List<int>.filled(48, 1),
  'tokens.txt': List<int>.filled(6, 2),
};

/// 构造测试音色（HF 逐文件布局：onnx + tokens + 共享 espeak 依赖）。
PiperVoice _testVoice({Map<String, String>? shaOverrides}) {
  return PiperVoice(
    id: _testVoiceId,
    displayName: 'Test',
    accent: TtsAccent.us,
    isFemale: true,
    license: 'public domain',
    resource: AsrPublicResourceSpec(
      id: _testVoiceId,
      repository: 'example/piper-test',
      revision: 'v1',
      layout: AsrPublicResourceLayout.huggingFaceResolve,
      license: 'public domain',
      files: [
        for (final entry in _modelFiles.entries)
          AsrResourceFile(
            name: entry.key,
            sha256:
                shaOverrides?[entry.key] ??
                sha256.convert(entry.value).toString(),
            sizeBytes: entry.value.length,
          ),
      ],
      dependencies: const ['espeak-ng-data'],
    ),
  );
}

/// 构造 espeak-ng-data 独立资源规格及其注册表（供只补修复分支使用）。
Map<String, AsrPublicResourceSpec> _espeakRegistry(
  List<int> archive, {
  String? shaOverride,
}) {
  final resource = AsrPublicResourceSpec(
    id: 'espeak-ng-data',
    repository: 'example/models',
    revision: 'tts-models',
    layout: AsrPublicResourceLayout.githubReleaseAsset,
    license: 'GPL-3.0-or-later',
    files: [
      AsrResourceFile(
        name: 'espeak-ng-data.tar.gz',
        sha256: shaOverride ?? sha256.convert(archive).toString(),
        sizeBytes: archive.length,
      ),
    ],
  );
  return {'espeak-ng-data': resource};
}

PiperModelManager _manager(
  Directory root, {
  PiperVoice? voice,
  Map<String, String>? shaOverrides,
  String? espeakShaOverride,
  HttpClientAdapter? adapter,
  List<Uri>? requestUris,
}) {
  final payloads = <String, List<int>>{
    ..._modelFiles,
    'espeak-ng-data.tar.gz': _buildEspeakArchive(),
  };
  final dio = Dio();
  dio.httpClientAdapter =
      adapter ?? _MockFileAdapter(payloads, requestUris: requestUris);
  return PiperModelManager(
    dio: dio,
    baseUrlOverride: 'http://mock.local',
    voice: voice ?? _testVoice(shaOverrides: shaOverrides),
    resourceRegistryOverride: _espeakRegistry(
      payloads['espeak-ng-data.tar.gz']!,
      shaOverride: espeakShaOverride,
    ),
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

  test('逐文件下载 → 校验 → 安装：onnx/tokens/espeak-ng-data 就位', () async {
    final requestedUris = <Uri>[];
    final manager = _manager(root, requestUris: requestedUris);

    final progresses = <double>[];
    await manager.downloadModel(
      onProgress: (progress) => progresses.add(progress.progress),
    );

    expect(
      requestedUris.map((u) => u.path).toList(),
      ['/$_testVoiceId.onnx', '/tokens.txt', '/espeak-ng-data.tar.gz'],
    );
    expect(await manager.isModelDownloaded(), isTrue);
    final paths = await manager.piperConfigPaths();
    expect(File(paths.model).existsSync(), isTrue);
    expect(File(paths.tokens).existsSync(), isTrue);
    expect(p.basename(paths.dataDir), 'espeak-ng-data');
    expect(File(p.join(paths.dataDir, 'phondata')).existsSync(), isTrue);
    expect(progresses.last, 1.0);
    // espeak 依赖装在音色目录内，不在 tts-models 顶层。
    expect(Directory(p.join(root.path, 'espeak-ng-data')).existsSync(), isFalse);
  });

  test('真实目录：按 HF resolve + 固定 revision 构造下载地址', () {
    final voice = piperVoiceById(piperDefaultVoiceUk);
    expect(voice, isNotNull);
    final resource = voice!.resource;
    final onnx = resource.files.first;
    expect(
      resource.fileUri(AsrDownloadSource.huggingFace, onnx).toString(),
      'https://huggingface.co/${resource.repository}/resolve/'
      '${resource.revision}/${onnx.name}',
    );
  });

  test('单文件 SHA-256 不匹配 → 抛错且模型未安装', () async {
    final manager = _manager(
      root,
      shaOverrides: {'$_testVoiceId.onnx': 'deadbeef'},
    );

    await expectLater(manager.downloadModel(), throwsA(isA<StateError>()));
    expect(await manager.isModelDownloaded(), isFalse);
    expect(Directory(await manager.modelDir()).existsSync(), isFalse);
  });

  test('下载网络失败 → 抛结构化异常且不留 .part 残留', () async {
    final manager = _manager(root, adapter: _AlwaysNotFoundAdapter());

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
    final leftovers = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.part'));
    expect(leftovers, isEmpty);
  });

  test('预置 .part → 使用 Range 续传并在安装后清理残留', () async {
    final onnxBytes = _modelFiles['$_testVoiceId.onnx']!;
    final onnxSha = sha256.convert(onnxBytes).toString();
    final partialLength = onnxBytes.length ~/ 2;
    final downloadDir = Directory(p.join(root.path, '_download_$_testVoiceId'));
    await downloadDir.create(recursive: true);
    final partial = File(p.join(downloadDir.path, '$_testVoiceId.onnx.part'));
    await partial.writeAsBytes(onnxBytes.sublist(0, partialLength));
    await File('${partial.path}.meta.json').writeAsString(
      '{"identityKey":"$onnxSha","downloadedBytes":$partialLength}',
    );
    final adapter = _MockFileAdapter({
      ..._modelFiles,
      'espeak-ng-data.tar.gz': _buildEspeakArchive(),
    });
    final manager = _manager(root, adapter: adapter);

    await manager.downloadModel();

    expect(adapter.requests.first['Range'], 'bytes=$partialLength-');
    expect(await manager.isModelDownloaded(), isTrue);
    expect(partial.existsSync(), isFalse);
    expect(downloadDir.existsSync(), isFalse);
  });

  test('安装失败不会覆盖已有模型，staging 会清理', () async {
    final valid = _manager(root);
    await valid.downloadModel();
    final installedOnnx = File(
      p.join(await valid.modelDir(), '$_testVoiceId.onnx'),
    );
    expect(installedOnnx.existsSync(), isTrue);

    final invalid = _manager(
      root,
      shaOverrides: {'tokens.txt': 'deadbeef'},
    );
    await expectLater(invalid.downloadModel(), throwsA(isA<StateError>()));

    expect(installedOnnx.existsSync(), isTrue);
    expect(await valid.isModelDownloaded(), isTrue);
    expect(
      root.listSync().whereType<Directory>().where(
        (directory) => p.basename(directory.path).startsWith('_staging_'),
      ),
      isEmpty,
    );
  });

  test('deleteModel 清理模型目录与下载残留', () async {
    final manager = _manager(root);
    await manager.downloadModel();
    final downloadDir = Directory(p.join(root.path, '_download_$_testVoiceId'));
    await downloadDir.create(recursive: true);
    await File(p.join(downloadDir.path, 'tokens.txt.part')).writeAsBytes([1]);
    final staging = Directory(p.join(root.path, '_staging_${_testVoiceId}_old'));
    await staging.create(recursive: true);

    await manager.deleteModel();

    expect(await manager.isModelDownloaded(), isFalse);
    expect(await manager.modelLocalSize(), 0);
    expect(downloadDir.existsSync(), isFalse);
    expect(staging.existsSync(), isFalse);
  });

  test('espeak 缺失时只下 espeak 归档且模型不重下', () async {
    final requested = <Uri>[];
    final manager = _manager(root, requestUris: requested);
    await manager.downloadModel();
    requested.clear();

    final dataDir = Directory(
      p.join(await manager.modelDir(), 'espeak-ng-data'),
    );
    await dataDir.delete(recursive: true);
    expect(await manager.isModelDownloaded(), isFalse);

    await manager.downloadModel();
    expect(
      requested.map((u) => u.pathSegments.last).toList(),
      ['espeak-ng-data.tar.gz'],
    );
    expect(await manager.isModelDownloaded(), isTrue);
    expect(File(p.join(dataDir.path, 'phondata')).existsSync(), isTrue);
  });

  test('espeak 目录存在但 phondata 缺失 → 视为未下载且只补 espeak', () async {
    final requested = <Uri>[];
    final manager = _manager(root, requestUris: requested);
    await manager.downloadModel();
    requested.clear();

    final dataDir = Directory(
      p.join(await manager.modelDir(), 'espeak-ng-data'),
    );
    await File(p.join(dataDir.path, 'phondata')).delete();
    expect(await manager.isModelDownloaded(), isFalse);

    await manager.downloadModel();
    expect(
      requested.map((u) => u.pathSegments.last).toList(),
      ['espeak-ng-data.tar.gz'],
    );
    expect(await manager.isModelDownloaded(), isTrue);
  });

  test('espeak 修复失败 → 抛错且模型本体保留', () async {
    final good = _manager(root);
    await good.downloadModel();
    final modelDir = await good.modelDir();
    await Directory(p.join(modelDir, 'espeak-ng-data')).delete(recursive: true);

    final bad = _manager(root, espeakShaOverride: 'deadbeef');
    await expectLater(bad.downloadModel(), throwsA(isA<StateError>()));

    expect(File(p.join(modelDir, '$_testVoiceId.onnx')).existsSync(), isTrue);
    expect(await bad.isModelDownloaded(), isFalse);
  });
}
