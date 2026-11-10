/// Kokoro TTS 模型公开资源目录。
///
/// Kokoro fp32/int8 两个变体与共享 `espeak-ng-data` 都从固定公开来源整包
/// 下载（本项目 GitHub Releases 托管的 gzip 重打包），逐文件内容与上游
/// `k2-fsa/sherpa-onnx` 的 `tts-models` 官方资产一致。下载与安装流程由
/// [KokoroModelManager] 负责。核验记录见
/// `docs/features/20261110-tts-provider-decoupling/public-source-verification.md`。
library;

import '../asr/asr_model_catalog.dart'
    show
        AsrDownloadSource,
        AsrPublicResourceLayout,
        AsrPublicResourceSpec,
        AsrResourceFile;
import 'tts_engine.dart' show KokoroModelVariant;

/// espeak-ng-data 共享依赖资源 ID（Kokoro 与 Piper 共用一份）。
const kokoroEspeakNgDataResourceId = 'espeak-ng-data';

/// Kokoro 公开资源的固定仓库。
///
/// 最终托管位置待操作者确认；仓库名集中在此常量，若改名/改位置只动这一处。
const kokoroPublicRepository = 'iron6909/loop-back-models';

/// 固定发布 tag（与 sherpa 上游同名对齐）。
const kokoroPublicRevision = 'tts-models';

/// 默认 Kokoro 模型变体。
const kokoroDefaultVariant = KokoroModelVariant.fp32;

/// Kokoro 推理所需的固定文件名。
const kokoroVoicesFileName = 'voices.bin';
const kokoroTokensFileName = 'tokens.txt';
const kokoroDataDirectoryName = 'espeak-ng-data';

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

  /// 归档文件名（资源目录里唯一的整包文件）。
  String get archiveFileName => resource.files.single.name;

  /// 整包 SHA-256（发布资产可被替换的风险由安装时校验兜底）。
  String get sha256 => resource.files.single.sha256;

  /// 预计下载字节数（整包）。
  int get estimatedDownloadBytes => resource.estimatedDownloadBytes;

  /// 共享依赖资源 ID。
  List<String> get dependencies => resource.dependencies;

  /// 指定下载源下的归档 URI。GitHub 发布资产无已核实镜像，选镜像时仍走上游。
  Uri fileUri(AsrDownloadSource source) =>
      resource.fileUri(source, resource.files.single);
}

/// Kokoro 共享发音数据 `espeak-ng-data` 的固定公开资源身份。
final kokoroEspeakNgDataResource = AsrPublicResourceSpec(
  id: kokoroEspeakNgDataResourceId,
  repository: kokoroPublicRepository,
  revision: kokoroPublicRevision,
  layout: AsrPublicResourceLayout.githubReleaseAsset,
  license: 'GPL-3.0-or-later',
  files: const [
    AsrResourceFile(
      name: 'espeak-ng-data.tar.gz',
      sha256:
          '6ebdff81e71e67e6cc4caac37a28ebfe38b364db5cbac66746efc94403abb8a2',
      sizeBytes: 8986848,
    ),
  ],
);

/// Kokoro 模型规格表。
final kokoroModelSpecs = <KokoroModelVariant, KokoroModelSpec>{
  KokoroModelVariant.fp32: KokoroModelSpec(
    variant: KokoroModelVariant.fp32,
    id: 'kokoro-en-v0_19',
    modelFileName: 'model.onnx',
    resource: AsrPublicResourceSpec(
      id: 'kokoro-en-v0_19',
      repository: kokoroPublicRepository,
      revision: kokoroPublicRevision,
      layout: AsrPublicResourceLayout.githubReleaseAsset,
      license: 'Apache-2.0',
      files: const [
        AsrResourceFile(
          name: 'kokoro-en-v0_19.tar.gz',
          sha256:
              'd97c85ba5777bc226eca3a40312bb29dd8fd0e77546d4100abb7243b9b6ad137',
          sizeBytes: 313785757,
        ),
      ],
      dependencies: const [kokoroEspeakNgDataResourceId],
    ),
  ),
  KokoroModelVariant.int8: KokoroModelSpec(
    variant: KokoroModelVariant.int8,
    id: 'kokoro-en-v0_19-int8',
    modelFileName: 'model.int8.onnx',
    resource: AsrPublicResourceSpec(
      id: 'kokoro-en-v0_19-int8',
      repository: kokoroPublicRepository,
      revision: kokoroPublicRevision,
      layout: AsrPublicResourceLayout.githubReleaseAsset,
      license: 'Apache-2.0',
      files: const [
        AsrResourceFile(
          name: 'kokoro-en-v0_19-int8-v2.tar.gz',
          sha256:
              '70fd7ff687d08245f9409557f58072f43eb8a5bf8a90e98dd3bb7f60e05b4b07',
          sizeBytes: 102614756,
        ),
      ],
      dependencies: const [kokoroEspeakNgDataResourceId],
    ),
  ),
};

/// 全部 Kokoro 公开资源（两变体 + 共享 espeak-ng-data）。
final kokoroPublicResourceCatalog = <String, AsrPublicResourceSpec>{
  for (final spec in kokoroModelSpecs.values) spec.id: spec.resource,
  kokoroEspeakNgDataResourceId: kokoroEspeakNgDataResource,
};

/// 按变体读取 Kokoro 模型规格。
KokoroModelSpec kokoroSpecOf(KokoroModelVariant variant) =>
    kokoroModelSpecs[variant]!;
