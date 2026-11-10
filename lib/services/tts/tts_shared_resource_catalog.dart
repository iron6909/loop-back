/// TTS 引擎共享的公开资源目录。
///
/// `espeak-ng-data` 是 Kokoro 与 Piper 的共享发音数据依赖（D12）：两个引擎的
/// 模型都带同一份 355 文件目录树，缺失时只补该依赖。这里只放共享资源身份，
/// 引擎各自的模型目录仍分别在 `kokoro_model_catalog.dart` / `piper_model_catalog.dart`。
library;

// 与 #21 一致，复用 ASR 公开资源描述类型，不另起 TTS 版本。
import '../asr/asr_model_catalog.dart'
    show AsrPublicResourceLayout, AsrPublicResourceSpec, AsrResourceFile;

/// TTS 共享依赖的统一资源 ID。
const ttsEspeakNgDataResourceId = 'espeak-ng-data';

/// TTS 重打包资产的固定公开仓库（GitHub Releases）。
const ttsPublicRepository = 'iron6909/loop-back-models';

/// TTS 重打包资产的固定发布 tag。
const ttsPublicRevision = 'tts-models';

/// espeak-ng-data 归档文件名。
const ttsEspeakNgDataFileName = 'espeak-ng-data.tar.gz';

/// espeak-ng-data 的固定公开资源身份（托管于 `iron6909/loop-back-models`）。
///
/// 内容与 sherpa-onnx 官方 `espeak-ng-data` 逐文件一致（355 文件，见核验记录）。
/// GitHub 发布资产无已核实镜像，来源切换时仍走上游（D8）。
final ttsEspeakNgDataResource = AsrPublicResourceSpec(
  id: ttsEspeakNgDataResourceId,
  repository: ttsPublicRepository,
  revision: ttsPublicRevision,
  layout: AsrPublicResourceLayout.githubReleaseAsset,
  license: 'GPL-3.0-or-later',
  files: const [
    AsrResourceFile(
      name: ttsEspeakNgDataFileName,
      sha256:
          '6ebdff81e71e67e6cc4caac37a28ebfe38b364db5cbac66746efc94403abb8a2',
      sizeBytes: 8986848,
    ),
  ],
);
