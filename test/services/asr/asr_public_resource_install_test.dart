import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:echo_loop/services/asr/asr_model_manager.dart';
import 'package:echo_loop/services/download/download_failure.dart';
import 'package:echo_loop/services/reliable_http_downloader.dart';

/// 按 URI 返回固定内容或注入网络失败的假 HTTP adapter。
class _ServingAdapter implements HttpClientAdapter {
  _ServingAdapter(this.payloads);

  final Map<String, List<int>> payloads;
  final List<Uri> requests = [];
  final List<Map<String, Object?>> requestHeaders = [];

  /// 指定 URI 的剩余失败次数：用来模拟断网。
  final Map<String, int> networkFailures = {};

  /// 指定 URI 返回的错误内容：用来模拟摘要不符。
  final Map<String, List<int>> tampered = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? _,
    Future<void>? __,
  ) async {
    final uri = options.uri;
    requests.add(uri);
    requestHeaders.add(Map<String, Object?>.from(options.headers));
    final remainingFailures = networkFailures[uri.toString()] ?? 0;
    if (remainingFailures > 0) {
      networkFailures[uri.toString()] = remainingFailures - 1;
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'simulated offline',
      );
    }
    final payload = tampered[uri.toString()] ?? payloads[uri.toString()];
    if (payload == null) {
      return ResponseBody(Stream.value(Uint8List(0)), 404, headers: const {});
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
        'content-range': [
          'bytes $start-${payload.length - 1}/${payload.length}',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _modelId = 'whisper-tiny-en-int8';
const _repository = 'example/sherpa-onnx-whisper-test';

final _encoderBytes = List<int>.generate(64, (index) => index);
final _tokensBytes = List<int>.generate(32, (index) => 255 - index);
final _vadBytes = List<int>.generate(16, (index) => index * 3);

AsrResourceFile _file(String name, List<int> payload) => AsrResourceFile(
  name: name,
  sha256: sha256.convert(payload).toString(),
  sizeBytes: payload.length,
);

/// 用两段小文件构造公开资源，避免测试依赖真实大模型。
AsrPublicResourceSpec _modelSpec({
  List<int>? encoder,
  List<int>? tokens,
  List<String> dependencies = const [vadModelId],
}) {
  return AsrPublicResourceSpec(
    id: _modelId,
    repository: _repository,
    revision: 'rev1',
    layout: AsrPublicResourceLayout.huggingFaceResolve,
    license: 'MIT',
    files: [
      _file('tiny.en-encoder.int8.onnx', encoder ?? _encoderBytes),
      _file('tiny.en-tokens.txt', tokens ?? _tokensBytes),
    ],
    dependencies: dependencies,
  );
}

AsrPublicResourceSpec _vadSpec() => AsrPublicResourceSpec(
  id: vadModelId,
  repository: 'example/sherpa-onnx',
  revision: 'asr-models',
  layout: AsrPublicResourceLayout.githubReleaseAsset,
  license: 'MIT',
  files: [_file('silero_vad.onnx', _vadBytes)],
);

class _Harness {
  _Harness({
    required this.root,
    required this.modelSpec,
    required this.vadSpec,
    required this.adapter,
  });

  final Directory root;
  final AsrPublicResourceSpec modelSpec;
  final AsrPublicResourceSpec vadSpec;
  final _ServingAdapter adapter;

  /// 安装完成后由 [_createHarness] 注入，保存发布阶段的改名注入点所需的可变状态。
  late final AsrModelManager manager;

  /// 置为 true 后发布阶段的目录改名失败，用来验证旧安装回滚。
  bool failPublish = false;

  Future<String> modelDir() => manager.modelDir(_modelId);
  Future<String> vadDir() => manager.modelDir(vadModelId);

  Uri modelFileUri(AsrResourceFile file, [AsrDownloadSource? source]) =>
      modelSpec.fileUri(source ?? AsrDownloadSource.huggingFace, file);
}

Future<_Harness> _createHarness({
  List<String> dependencies = const [vadModelId],
  bool failPublish = false,
}) async {
  final root = await Directory.systemTemp.createTemp('asr-public-install');
  addTearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });
  final modelSpec = _modelSpec(dependencies: dependencies);
  final vadSpec = _vadSpec();
  final payloads = <String, List<int>>{
    for (final source in AsrDownloadSource.values)
      for (final file in modelSpec.files)
        modelSpec.fileUri(source, file).toString():
            modelSpec.files.indexOf(file) == 0 ? _encoderBytes : _tokensBytes,
    for (final source in AsrDownloadSource.values)
      for (final file in vadSpec.files)
        vadSpec.fileUri(source, file).toString(): _vadBytes,
  };
  final adapter = _ServingAdapter(payloads);
  final dio = Dio()..httpClientAdapter = adapter;
  final harness = _Harness(
    root: root,
    modelSpec: modelSpec,
    vadSpec: vadSpec,
    adapter: adapter,
  )..failPublish = failPublish;
  harness.manager = AsrModelManager(
    dio: dio,
    baseUrlOverride: 'http://mock.local',
    modelsRootResolver: () async => p.join(root.path, 'models'),
    downloader: DioReliableHttpDownloader(
      dio: dio,
      backoffDelay: (duration) async {},
    ),
    resourceRegistryOverride: {_modelId: modelSpec, vadModelId: vadSpec},
    // 发布阶段的目录改名注入点：模拟权限/占用导致的真实发布失败。
    renameDirectory: (from, to) async {
      if (harness.failPublish && p.basename(from).startsWith('_staging_')) {
        throw const FileSystemException('simulated publish failure');
      }
      await Directory(from).rename(to);
    },
  );
  addTearDown(harness.manager.dispose);
  return harness;
}

void main() {
  test('公开资源目录固定 Tiny 与共享 VAD 的公开版本、摘要、大小和许可', () {
    final tinyOrNull = asrPublicResourceCatalog[_modelId];
    final vadOrNull = asrPublicResourceCatalog[vadModelId];
    if (tinyOrNull is! AsrPublicResourceSpec ||
        vadOrNull is! AsrPublicResourceSpec) {
      throw StateError('公开资源目录缺少 Tiny 或 VAD');
    }
    final tiny = tinyOrNull;
    final vad = vadOrNull;
    expect(tiny.repository, 'csukuangfj/sherpa-onnx-whisper-tiny.en');
    expect(tiny.revision, 'd026532c022fa99fd789d6b32446a1df7b6bfc43');
    expect(tiny.license, 'MIT');
    expect(tiny.dependencies, [vadModelId]);
    expect(
      tiny.fileUri(AsrDownloadSource.huggingFace, tiny.files.first).toString(),
      'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny.en/resolve/'
      'd026532c022fa99fd789d6b32446a1df7b6bfc43/tiny.en-encoder.int8.onnx',
    );
    expect(tiny.files.map((file) => file.name), [
      'tiny.en-encoder.int8.onnx',
      'tiny.en-decoder.int8.onnx',
      'tiny.en-tokens.txt',
    ]);
    // 上游与镜像只换域名，版本、路径与摘要完全相同。
    for (final file in tiny.files) {
      final upstream = tiny.fileUri(AsrDownloadSource.huggingFace, file);
      final mirror = tiny.fileUri(AsrDownloadSource.huggingFaceMirror, file);
      expect(upstream.path, mirror.path);
      expect(upstream.host, 'huggingface.co');
      expect(mirror.host, 'hf-mirror.com');
    }
    expect(
      tiny.files[0].sha256,
      '0ce578b827c94a961aacb8fa14b02f096504b337e5c94be37c36238cbe3e8bc6',
    );
    expect(
      tiny.files[1].sha256,
      '06c0e6ff6348d427e51839219d1c886c18cfdf411e629e33f5e1679bff9c1527',
    );
    expect(
      tiny.files[2].sha256,
      '306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930',
    );
    expect(tiny.files[0].sizeBytes, 12937772);
    expect(tiny.files[1].sizeBytes, 89853865);
    expect(tiny.files[2].sizeBytes, 835554);
    expect(tiny.estimatedDownloadBytes, 12937772 + 89853865 + 835554);

    expect(vad.files.single.name, 'silero_vad.onnx');
    expect(
      vad.files.single.sha256,
      '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
    );
    expect(vad.files.single.sizeBytes, 643854);
    expect(vad.license, 'MIT');
    expect(
      vad.fileUri(AsrDownloadSource.huggingFace, vad.files.single).toString(),
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
      'silero_vad.onnx',
    );
    // VAD 只有 GitHub 一个已核实来源，镜像选择不改变其地址。
    expect(
      vad.fileUri(AsrDownloadSource.huggingFaceMirror, vad.files.single),
      vad.fileUri(AsrDownloadSource.huggingFace, vad.files.single),
    );
  });

  test('逐文件下载到临时目录，校验通过后才发布并写入安装清单', () async {
    final harness = await _createHarness();
    final progress = <double>[];

    await harness.manager.downloadModel(
      _modelId,
      onProgress: (value) => progress.add(value.progress),
    );

    final modelDir = Directory(await harness.modelDir());
    expect(
      await File(
        p.join(modelDir.path, 'tiny.en-encoder.int8.onnx'),
      ).readAsBytes(),
      _encoderBytes,
    );
    expect(
      await File(p.join(modelDir.path, 'tiny.en-tokens.txt')).readAsBytes(),
      _tokensBytes,
    );
    final manifest = await harness.manager.readInstallManifest(_modelId);
    expect(manifest?.resourceId, _modelId);
    expect(manifest?.resourceSize, greaterThan(0));
    expect(await harness.manager.isModelDownloaded(_modelId), isTrue);
    expect(progress.last, 1);
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
    }
    // 安装完成后不保留下载中间目录。
    expect(
      Directory(
        p.join(harness.root.path, 'models', '_download_$_modelId'),
      ).existsSync(),
      isFalse,
    );
  });

  test('镜像切换使用同一版本与摘要，断点按文件摘要续传', () async {
    final harness = await _createHarness();
    final encoder = harness.modelSpec.files.first;

    // 上游下载到一半后中断，保留 .part 与文件摘要身份。
    final downloadDir = Directory(
      p.join(harness.root.path, 'models', '_download_$_modelId'),
    );
    await downloadDir.create(recursive: true);
    final partial = File(p.join(downloadDir.path, encoder.name));
    await partial.writeAsBytes(_encoderBytes.sublist(0, 20));
    await File(
      '${partial.path}.part',
    ).writeAsBytes(_encoderBytes.sublist(0, 20));
    await File(
      '${partial.path}.part.meta.json',
    ).writeAsString('{"identityKey":"${encoder.sha256}"}');

    await harness.manager.downloadModel(
      _modelId,
      source: AsrDownloadSource.huggingFaceMirror,
    );

    final rangeRequest = harness.adapter.requestHeaders.firstWhere(
      (headers) => headers.containsKey('Range'),
    );
    expect(rangeRequest['Range'], 'bytes=20-');
    final modelRequests = harness.adapter.requests.where(
      (uri) => uri.path.contains('/resolve/rev1/'),
    );
    expect(modelRequests, isNotEmpty);
    expect(modelRequests.map((uri) => uri.host), everyElement('hf-mirror.com'));
    expect(
      modelRequests.map((uri) => uri.path),
      contains(harness.modelFileUri(encoder).path),
    );
    expect(
      await File(p.join(await harness.modelDir(), encoder.name)).readAsBytes(),
      _encoderBytes,
    );
    // VAD 没有等价镜像，仍使用其唯一固定公开来源。
    expect(
      harness.adapter.requests.map((uri) => uri.host),
      contains('github.com'),
    );
  });

  test('摘要不符时报校验失败，且不损坏已有安装文件', () async {
    final harness = await _createHarness();
    await harness.manager.downloadModel(_modelId);
    final modelDir = Directory(await harness.modelDir());
    // 删除安装清单并改写旧文件，模拟安装损坏后重试：旧内容必须保留到校验通过为止。
    await File(p.join(modelDir.path, 'install.json')).delete();
    final previousBytes = List<int>.filled(64, 5);
    await File(
      p.join(modelDir.path, 'tiny.en-encoder.int8.onnx'),
    ).writeAsBytes(previousBytes);
    harness.adapter.tampered[harness
        .modelFileUri(harness.modelSpec.files.first)
        .toString()] = List<int>.filled(
      64,
      7,
    );

    Object? error;
    try {
      await harness.manager.downloadModel(_modelId);
    } catch (caught) {
      error = caught;
    }

    expect(error, isNotNull);
    expect(error.toString(), contains('SHA-256'));
    expect(classifyDownloadFailure(error!), DownloadFailureKind.verification);
    expect(
      await File(
        p.join(modelDir.path, 'tiny.en-encoder.int8.onnx'),
      ).readAsBytes(),
      previousBytes,
    );
  });

  test('用户取消后不发布安装，也不破坏旧安装', () async {
    final harness = await _createHarness();
    final cancelToken = CancelToken()..cancel();

    Object? error;
    try {
      await harness.manager.downloadModel(_modelId, cancelToken: cancelToken);
    } catch (caught) {
      error = caught;
    }

    expect(error, isA<ReliableDownloadException>());
    if (error is ReliableDownloadException) {
      expect(error.kind, ReliableDownloadFailure.cancelled);
    }
    expect(await harness.manager.isModelDownloaded(_modelId), isFalse);
    expect(Directory(await harness.modelDir()).existsSync(), isFalse);
  });

  test('断网中断保留已下载文件，恢复后只续传未完成文件', () async {
    final harness = await _createHarness();
    final encoder = harness.modelSpec.files.first;
    final tokens = harness.modelSpec.files.last;
    harness.adapter.networkFailures[harness.modelFileUri(tokens).toString()] =
        99;

    Object? error;
    try {
      await harness.manager.downloadModel(_modelId);
    } catch (caught) {
      error = caught;
    }
    expect(error, isA<ReliableDownloadException>());
    expect(await harness.manager.isModelDownloaded(_modelId), isFalse);

    harness.adapter.networkFailures.clear();
    harness.adapter.requests.clear();
    await harness.manager.downloadModel(_modelId);

    // 已校验完成的编码器文件不重复下载，只补未完成的 tokens 与 VAD。
    expect(
      harness.adapter.requests.map((uri) => uri.path),
      isNot(contains(harness.modelFileUri(encoder).path)),
    );
    expect(
      harness.adapter.requests.map((uri) => uri.path),
      contains(harness.modelFileUri(tokens).path),
    );
    expect(await harness.manager.isModelDownloaded(_modelId), isTrue);
  });

  test('缺 VAD 时只补共享 VAD，不重下模型本体', () async {
    final harness = await _createHarness();
    await harness.manager.downloadModel(_modelId);
    await harness.manager.deleteModel(vadModelId);
    harness.adapter.requests.clear();

    await harness.manager.downloadModel(_modelId);

    expect(harness.adapter.requests, hasLength(1));
    expect(harness.adapter.requests.single.path, contains('silero_vad.onnx'));
    expect(await harness.manager.isModelDownloaded(vadModelId), isTrue);
    expect(await harness.manager.isModelDownloaded(_modelId), isTrue);
  });

  test('发布失败时回滚到旧安装', () async {
    final harness = await _createHarness();
    await harness.manager.downloadModel(_modelId);
    final modelDir = Directory(await harness.modelDir());
    // 旧安装缺失必需文件 → 触发重装；旧文件内容用于识别是否被新下载覆盖。
    await File(p.join(modelDir.path, 'tiny.en-tokens.txt')).delete();
    final previousBytes = List<int>.filled(64, 5);
    await File(
      p.join(modelDir.path, 'tiny.en-encoder.int8.onnx'),
    ).writeAsBytes(previousBytes);
    harness.failPublish = true;

    Object? error;
    try {
      await harness.manager.downloadModel(_modelId);
    } catch (caught) {
      error = caught;
    }

    expect(error, isA<FileSystemException>());
    expect(
      await File(
        p.join(modelDir.path, 'tiny.en-encoder.int8.onnx'),
      ).readAsBytes(),
      previousBytes,
    );
    // 回滚后仍是原来的不完整安装，而不是半发布的新安装。
    expect(
      File(p.join(modelDir.path, 'tiny.en-tokens.txt')).existsSync(),
      isFalse,
    );
  });

  test('旧归档安装清单仍然被识别为已安装，不触发重下', () async {
    final harness = await _createHarness();
    final modelDir = Directory(await harness.modelDir());
    await modelDir.create(recursive: true);
    await File(
      p.join(modelDir.path, 'tiny.en-encoder.int8.onnx'),
    ).writeAsBytes(_encoderBytes);
    await File(
      p.join(modelDir.path, 'tiny.en-tokens.txt'),
    ).writeAsBytes(_tokensBytes);
    await File(p.join(modelDir.path, 'install.json')).writeAsString(
      '{"resourceId":"$_modelId","installAt":"2025-01-01T00:00:00.000Z",'
      '"resourceSize":96}',
    );
    final vadDir = Directory(await harness.vadDir());
    await vadDir.create(recursive: true);
    await File(p.join(vadDir.path, 'silero_vad.onnx')).writeAsBytes(_vadBytes);
    await File(p.join(vadDir.path, 'install.json')).writeAsString(
      '{"resourceId":"$vadModelId","installAt":"2025-01-01T00:00:00.000Z",'
      '"resourceSize":16}',
    );

    expect(await harness.manager.isModelDownloaded(_modelId), isTrue);
    await harness.manager.downloadModel(_modelId);
    expect(harness.adapter.requests, isEmpty);
    expect(
      (await harness.manager.readInstallManifest(_modelId))?.resourceSize,
      96,
    );
  });
}
