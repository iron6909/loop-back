import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:loop_back/services/asr/asr_model_manager.dart';
import 'package:loop_back/services/reliable_http_downloader.dart';

/// 按 URI 返回固定内容的假 HTTP adapter，用于构造公开资源安装流程。
class _ServingAdapter implements HttpClientAdapter {
  _ServingAdapter(this.payloads);

  final Map<String, List<int>> payloads;
  final List<Uri> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? _,
    Future<void>? __,
  ) async {
    requests.add(options.uri);
    final payload = payloads[options.uri.toString()];
    if (payload == null) {
      return ResponseBody(Stream.value(Uint8List(0)), 404, headers: const {});
    }
    return ResponseBody(
      Stream.value(Uint8List.fromList(payload)),
      200,
      headers: {
        'content-length': [payload.length.toString()],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _modelId = 'whisper-test-en-int8';

final _encoderBytes = List<int>.generate(64, (index) => index);
final _decoderBytes = List<int>.generate(48, (index) => 200 - index);
final _tokensBytes = List<int>.generate(32, (index) => 255 - index);
final _vadBytes = List<int>.generate(16, (index) => index * 3);

AsrResourceFile _file(String name, List<int> payload) => AsrResourceFile(
  name: name,
  sha256: sha256.convert(payload).toString(),
  sizeBytes: payload.length,
);

AsrPublicResourceSpec _modelSpec() => AsrPublicResourceSpec(
  id: _modelId,
  repository: 'example/sherpa-onnx-whisper-test.en',
  revision: 'rev1',
  layout: AsrPublicResourceLayout.huggingFaceResolve,
  license: 'MIT',
  files: [
    _file('test.en-encoder.int8.onnx', _encoderBytes),
    _file('test.en-decoder.int8.onnx', _decoderBytes),
    _file('test.en-tokens.txt', _tokensBytes),
  ],
  dependencies: const [vadModelId],
);

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
    required this.manager,
  });

  final Directory root;
  final AsrPublicResourceSpec modelSpec;
  final AsrPublicResourceSpec vadSpec;
  final _ServingAdapter adapter;
  final AsrModelManager manager;
}

Future<_Harness> _createHarness() async {
  final root = await Directory.systemTemp.createTemp('asr-manager-test');
  addTearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });
  final modelSpec = _modelSpec();
  final vadSpec = _vadSpec();
  final modelPayloads = [_encoderBytes, _decoderBytes, _tokensBytes];
  final adapter = _ServingAdapter({
    for (final source in AsrDownloadSource.values) ...{
      for (var i = 0; i < modelSpec.files.length; i++)
        modelSpec
            .fileUri(source, modelSpec.files[i])
            .toString(): modelPayloads[i],
      vadSpec
          .fileUri(source, vadSpec.files.single)
          .toString(): _vadBytes,
    },
  });
  final dio = Dio()..httpClientAdapter = adapter;
  final manager = AsrModelManager(
    dio: dio,
    modelsRootResolver: () async => p.join(root.path, 'models'),
    downloader: DioReliableHttpDownloader(
      dio: dio,
      backoffDelay: (duration) async {},
    ),
    resourceRegistryOverride: {_modelId: modelSpec, vadModelId: vadSpec},
  );
  addTearDown(manager.dispose);
  return _Harness(
    root: root,
    modelSpec: modelSpec,
    vadSpec: vadSpec,
    adapter: adapter,
    manager: manager,
  );
}

void main() {
  test('更早的逐文件安装按公开摘要识别，文件不符时不冒充已安装', () async {
    final harness = await _createHarness();
    final dir = Directory(await harness.manager.modelDir(_modelId));
    await dir.create(recursive: true);
    for (final file in harness.modelSpec.files) {
      final payload = switch (file.name) {
        'test.en-decoder.int8.onnx' => _decoderBytes,
        'test.en-tokens.txt' => _tokensBytes,
        _ => _encoderBytes,
      };
      await File(p.join(dir.path, file.name)).writeAsBytes(payload);
    }

    expect(await harness.manager.validateLegacyModelFiles(_modelId), isTrue);

    await File(
      p.join(dir.path, 'test.en-decoder.int8.onnx'),
    ).writeAsBytes(List<int>.filled(_decoderBytes.length, 7));
    expect(await harness.manager.validateLegacyModelFiles(_modelId), isFalse);
  });

  test('安装清单存在但文件被截断时不视为已安装，重新下载即可修复', () async {
    final harness = await _createHarness();
    await harness.manager.downloadModel(_modelId);
    final dir = Directory(await harness.manager.modelDir(_modelId));
    final encoder = File(p.join(dir.path, 'test.en-encoder.int8.onnx'));
    await encoder.writeAsBytes(_encoderBytes.sublist(0, 10));
    expect(await harness.manager.isModelDownloaded(_modelId), isFalse);
    harness.adapter.requests.clear();

    await harness.manager.downloadModel(_modelId);

    expect(await encoder.length(), _encoderBytes.length);
    expect(await harness.manager.isModelDownloaded(_modelId), isTrue);
    // 修复只补损坏的模型文件，已完整的共享 VAD 不重复安装。
    expect(
      harness.adapter.requests.map((uri) => uri.path),
      isNot(contains('silero_vad.onnx')),
    );
    // 修复后的安装清单可用，模型目录仍是同一个安装目录。
    expect(
      (await harness.manager.readInstallManifest(_modelId))?.resourceId,
      _modelId,
    );
  });

  test('安装流程只访问公开来源，不请求 LoopBack 资源服务', () async {
    final harness = await _createHarness();

    await harness.manager.downloadModel(
      _modelId,
      source: AsrDownloadSource.huggingFaceMirror,
    );

    expect(harness.adapter.requests, isNotEmpty);
    expect(
      harness.adapter.requests.map((uri) => uri.host),
      everyElement(isIn(['hf-mirror.com', 'github.com'])),
      reason: '三档模型与共享 VAD 都必须来自公开来源',
    );
  });

  test('删除模型和 VAD 半成品会在用户取消后清理', () async {
    final harness = await _createHarness();
    final modelsRoot = p.join(harness.root.path, 'models');
    final legacyArchivePartial = File(
      p.join(modelsRoot, '_download_$_modelId.zip.part'),
    );
    final vadPartial = File(
      p.join(modelsRoot, '_download_$vadModelId.zip.part'),
    );
    final filePartial = File(
      p.join(modelsRoot, '_download_$vadModelId', 'silero_vad.onnx.part'),
    );
    await vadPartial.parent.create(recursive: true);
    await legacyArchivePartial.writeAsBytes([1, 2, 3]);
    await File('${legacyArchivePartial.path}.meta.json').writeAsString('{}');
    await vadPartial.writeAsBytes([4, 5, 6]);
    await File('${vadPartial.path}.meta.json').writeAsString('{}');
    await filePartial.parent.create(recursive: true);
    await filePartial.writeAsBytes([7, 8, 9]);

    await harness.manager.discardPartialDownload(_modelId);
    await harness.manager.discardPartialDownload(vadModelId);

    expect(legacyArchivePartial.existsSync(), isFalse);
    expect(File('${legacyArchivePartial.path}.meta.json').existsSync(), isFalse);
    expect(vadPartial.existsSync(), isFalse);
    expect(File('${vadPartial.path}.meta.json').existsSync(), isFalse);
    expect(filePartial.existsSync(), isFalse);
  });

  test('缺少安装清单且文件与公开摘要不符的旧目录不会被当作已安装', () async {
    final harness = await _createHarness();
    final dir = Directory(await harness.manager.modelDir(_modelId));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'test.en-encoder.int8.onnx')).writeAsBytes([1]);

    expect(await harness.manager.readInstallManifest(_modelId), isNull);
    expect(await harness.manager.isModelDownloaded(_modelId), isFalse);
    expect(await harness.manager.validateLegacyModelFiles(_modelId), isFalse);
  });
}
