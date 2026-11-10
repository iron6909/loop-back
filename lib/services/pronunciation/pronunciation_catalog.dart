/// 内置离线发音包公开资源目录。
///
/// 发音包从固定 Hugging Face 数据集仓库整包下载（repository + revision +
/// 整包 SHA-256），上游与 hf-mirror.com 镜像只换下载域名、不换被信任的版本
/// 与摘要。复用 ASR 已建立的公开资源描述类型，不另起一套发音库版本。
/// 发音音频来源无法核实，按 ADR-0002 只标注托管仓库、不标注第三方许可。
library;

import '../asr/asr_model_catalog.dart'
    show AsrPublicResourceLayout, AsrPublicResourceSpec, AsrResourceFile;
import '../resource_archive_spec.dart';

/// 内置离线发音包资源规格。
class PronunciationSpec extends SingleFileArchiveSpec {
  const PronunciationSpec({
    required super.resourceId,
    required super.resource,
  });
}

/// 当前发布的离线发音包资源。
const pronunciationSpec = PronunciationSpec(
  resourceId: 'pronunciation-v2',
  resource: AsrPublicResourceSpec(
    id: 'pronunciation-v2',
    repository: dictionaryPronunciationPublicRepository,
    revision: dictionaryPronunciationPublicRevision,
    layout: AsrPublicResourceLayout.huggingFaceDatasetResolve,
    // 发音音频来源无法核实，只标注托管仓库，不虚构第三方许可（ADR-0002）。
    license: '',
    files: [
      AsrResourceFile(
        name: 'pronunciation-v2.zip',
        sha256:
            'db1bf8c8ec953f48ed05e22f8254cd8385f3c26f0acb630f73aedf14bbb6a1ca',
        sizeBytes: 41379389,
      ),
    ],
  ),
);
