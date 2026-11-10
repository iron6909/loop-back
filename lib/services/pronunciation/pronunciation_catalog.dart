/// 内置离线发音包公开资源目录。
///
/// 发音包从固定 Hugging Face 数据集仓库整包下载（repository + revision +
/// 整包 SHA-256），上游与 hf-mirror.com 镜像只换下载域名、不换被信任的版本
/// 与摘要。复用 ASR 已建立的公开资源描述类型，不另起一套发音库版本。
/// 发音音频来源无法核实，按 ADR-0002 只标注托管仓库、不标注第三方许可。
library;

import '../asr/asr_model_catalog.dart'
    show
        AsrDownloadSource,
        AsrPublicResourceLayout,
        AsrPublicResourceSpec,
        AsrResourceFile;

/// 发音包托管仓库（Hugging Face 数据集）与固定 revision。
///
/// 2026-11-10 双源独立下载核对通过：huggingface.co 与 hf-mirror.com 返回
/// 同一 revision 的相同字节，整包 SHA-256 与字节数同现有归档一致。
const pronunciationPublicRepository = 'banko3/loop-back';
const pronunciationPublicRevision = '3b3a5bef53a1c2c86f72117a8ce149554122baac';

/// 内置离线发音包资源规格。
class PronunciationSpec {
  const PronunciationSpec({
    required this.resourceId,
    required this.resource,
  });

  final String resourceId;

  /// 固定公开资源身份（repository/revision/layout/整包文件）。
  final AsrPublicResourceSpec resource;

  /// 归档文件名（公开资源目录里唯一的整包文件）。
  String get archiveFileName => resource.files.single.name;

  /// 整包 SHA-256。
  String get archiveSha256 => resource.files.single.sha256;

  /// 预计下载字节数（整包）。
  int get estimatedDownloadBytes => resource.estimatedDownloadBytes;

  /// 指定下载源下的归档 URI。上游与镜像只换域名，路径与摘要相同。
  Uri fileUri(AsrDownloadSource source) =>
      resource.fileUri(source, resource.files.single);
}

/// 当前发布的离线发音包资源。
final pronunciationSpec = PronunciationSpec(
  resourceId: 'pronunciation-v2',
  resource: AsrPublicResourceSpec(
    id: 'pronunciation-v2',
    repository: pronunciationPublicRepository,
    revision: pronunciationPublicRevision,
    layout: AsrPublicResourceLayout.huggingFaceDatasetResolve,
    // 发音音频来源无法核实，只标注托管仓库，不虚构第三方许可（ADR-0002）。
    license: '',
    files: const [
      AsrResourceFile(
        name: 'pronunciation-v2.zip',
        sha256:
            'db1bf8c8ec953f48ed05e22f8254cd8385f3c26f0acb630f73aedf14bbb6a1ca',
        sizeBytes: 41379389,
      ),
    ],
  ),
);
