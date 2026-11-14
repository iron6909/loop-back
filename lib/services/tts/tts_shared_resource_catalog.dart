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

/// TTS 重打包资产的固定公开仓库（GitHub Releases）；Piper 的三个整包音色仍从这里下载。
const ttsPublicRepository = 'iron6909/loop-back-models';

/// TTS 重打包资产的固定发布 tag。
const ttsPublicRevision = 'tts-models';

/// espeak-ng-data 归档的公开数据集仓库（Hugging Face dataset，可走 hf-mirror）。
const ttsEspeakNgDataRepository = 'banko3/loop-back';

/// espeak-ng-data 归档的固定 revision（上传后的 commit）。
const ttsEspeakNgDataRevision = '7babd0ff3f2cb572b10385823474c788ad2dc962';

/// espeak-ng-data 归档文件名。
const ttsEspeakNgDataFileName = 'espeak-ng-data.tar.gz';

/// espeak-ng-data 的固定公开资源身份（托管于 HF dataset `banko3/loop-back`）。
///
/// 内容与 sherpa-onnx 官方 `espeak-ng-data` 逐文件一致（355 文件，见核验记录）。
/// 走 HF dataset 而非 GitHub 发布资产，是为了支持 hf-mirror.com 切换（GitHub
/// 资产无已核实镜像，D8）。`iron6909/loop-back-models` 的 `tts-models` tag 里
/// 保留着同一份文件的旧副本，仅供已发布的老版本继续下载，不要删除。
final ttsEspeakNgDataResource = AsrPublicResourceSpec(
  id: ttsEspeakNgDataResourceId,
  repository: ttsEspeakNgDataRepository,
  revision: ttsEspeakNgDataRevision,
  layout: AsrPublicResourceLayout.huggingFaceDatasetResolve,
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
