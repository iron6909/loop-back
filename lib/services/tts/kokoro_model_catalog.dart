/// Kokoro TTS 模型公开资源目录。
///
/// 模型为 Kokoro v1.0 多语言版（53 发音人，英文占 sid 0..27），fp32/int8 两个变体
/// 分别从上游 sherpa-onnx 的 Hugging Face 仓库逐文件下载（HF resolve 布局），
/// 与 `k2-fsa/sherpa-onnx` 官方 `tts-models` 发布资产同源。两个变体共用同一份
/// `voices.bin` 与 `tokens.txt`；`espeak-ng-data` 仍是共享依赖（v1.0 的英文 G2P
/// 走 espeak），由 [ttsEspeakNgDataResource] 提供，缺失时只补该依赖。
/// 下载与安装流程由 [KokoroModelManager] 负责。
library;

// 按方案「复用或泛化 ASR 公开资源目录抽象」有意复用 ASR 命名类型
// （AsrDownloadSource/AsrPublicResourceSpec 等），不另起一套 TTS 版本。
import '../asr/asr_model_catalog.dart'
    show
        AsrDownloadSource,
        AsrPublicResourceLayout,
        AsrPublicResourceSpec,
        AsrResourceFile;
import 'tts_engine.dart' show KokoroModelVariant;
import 'tts_shared_resource_catalog.dart'
    show ttsEspeakNgDataResource, ttsEspeakNgDataResourceId;

/// 默认 Kokoro 模型变体。
const kokoroDefaultVariant = KokoroModelVariant.fp32;

/// Kokoro 推理所需的固定文件名。
const kokoroVoicesFileName = 'voices.bin';
const kokoroTokensFileName = 'tokens.txt';
const kokoroDataDirectoryName = 'espeak-ng-data';

/// v1.0 fp32 变体的安装目录名与资源 ID（历史版本 `kokoro-en-v0_19` 已退役）。
const kokoroV1ModelId = 'kokoro-multi-lang-v1_0';

/// v1.0 int8 变体的安装目录名与资源 ID。
const kokoroV1Int8ModelId = 'kokoro-multi-lang-v1_0-int8';

/// 已退役的 v0.19 模型目录名（启动迁移按此清理，避免残留 300+ MB）。
const kokoroLegacyModelIds = <String>[
  'kokoro-en-v0_19',
  'kokoro-en-v0_19-int8',
];

/// Kokoro 模型变体规格：绑定单个变体的公开资源身份。
class KokoroModelSpec {
  const KokoroModelSpec({
    required this.variant,
    required this.id,
    required this.modelFileName,
    required this.resource,
  });

  /// 精度变体。
  final KokoroModelVariant variant;

  /// 资源 ID，同时作为安装目录名与缓存键（必须保持稳定）。
  final String id;

  /// 推理文件名（`model.onnx` / `model.int8.onnx`）。
  final String modelFileName;

  /// 固定公开资源身份（repository/revision/layout/license/整包文件）。
  final AsrPublicResourceSpec resource;

  /// 预计下载字节数：模型文件 + 共享 `espeak-ng-data` 依赖（逐文件布局需单独下载）。
  int get estimatedDownloadBytes =>
      resource.estimatedDownloadBytes +
      ttsEspeakNgDataResource.estimatedDownloadBytes;

  /// 指定下载源下的归档 URI。GitHub 发布资产无已核实镜像，选镜像时仍走上游。
  Uri fileUri(AsrDownloadSource source) =>
      resource.fileUri(source, resource.files.single);
}

/// 两个变体共用的 tokons/voices 文件身份（v1.0 fp32 与 int8 仓库内逐字节一致）。
const _kokoroVoicesFileSha256 =
    '1c5a5b983d3d50d8586d437a51f3faa2da7919ce76a013c081e65671a3447c29';
const _kokoroVoicesFileSizeBytes = 28200960;
const _kokoroTokensFileSha256 =
    '6ebb6bb288f20f3ae8d004d3c2ca27697da27c037d75e81a60e2a6a663f95425';
const _kokoroTokensFileSizeBytes = 687;

/// 构造单个变体的 HF resolve 资源：模型文件 + 共用的 voices/tokens + espeak 依赖。
AsrPublicResourceSpec _kokoroV1Spec({
  required String id,
  required String repository,
  required String revision,
  required String modelFileName,
  required String modelSha256,
  required int modelSizeBytes,
}) {
  return AsrPublicResourceSpec(
    id: id,
    repository: repository,
    revision: revision,
    layout: AsrPublicResourceLayout.huggingFaceResolve,
    license: 'Apache-2.0',
    files: [
      AsrResourceFile(
        name: modelFileName,
        sha256: modelSha256,
        sizeBytes: modelSizeBytes,
      ),
      const AsrResourceFile(
        name: kokoroVoicesFileName,
        sha256: _kokoroVoicesFileSha256,
        sizeBytes: _kokoroVoicesFileSizeBytes,
      ),
      const AsrResourceFile(
        name: kokoroTokensFileName,
        sha256: _kokoroTokensFileSha256,
        sizeBytes: _kokoroTokensFileSizeBytes,
      ),
    ],
    dependencies: const [ttsEspeakNgDataResourceId],
  );
}

/// Kokoro 模型规格表。
final kokoroModelSpecs = <KokoroModelVariant, KokoroModelSpec>{
  KokoroModelVariant.fp32: KokoroModelSpec(
    variant: KokoroModelVariant.fp32,
    id: kokoroV1ModelId,
    modelFileName: 'model.onnx',
    resource: _kokoroV1Spec(
      id: kokoroV1ModelId,
      repository: 'csukuangfj/kokoro-multi-lang-v1_0',
      revision: 'f7b96bb6bef5c5da4d3aa4f4e0498fbbf62dc78b',
      modelFileName: 'model.onnx',
      modelSha256:
          'b40f62b166ac8164b0627ef48a0b358eda0985e272fb03ef5252e7206305da11',
      modelSizeBytes: 325560556,
    ),
  ),
  KokoroModelVariant.int8: KokoroModelSpec(
    variant: KokoroModelVariant.int8,
    id: kokoroV1Int8ModelId,
    modelFileName: 'model.int8.onnx',
    resource: _kokoroV1Spec(
      id: kokoroV1Int8ModelId,
      repository: 'csukuangfj/kokoro-int8-multi-lang-v1_0',
      revision: '57adb37fc0e8d4bd430cfc1b8f8c2294945b9af2',
      modelFileName: 'model.int8.onnx',
      modelSha256:
          '75635ea3b85a32d00094dcdd61a258aba87c160f7c264c304a7b3ae9d734195e',
      modelSizeBytes: 114202993,
    ),
  ),
};

/// 全部 Kokoro 公开资源（两变体 + 共享 espeak-ng-data，后者仅供只补修复与 Piper 复用）。
final kokoroPublicResourceCatalog = <String, AsrPublicResourceSpec>{
  for (final spec in kokoroModelSpecs.values) spec.id: spec.resource,
  ttsEspeakNgDataResourceId: ttsEspeakNgDataResource,
};

/// 按变体读取 Kokoro 模型规格。
KokoroModelSpec kokoroSpecOf(KokoroModelVariant variant) =>
    kokoroModelSpecs[variant]!;
