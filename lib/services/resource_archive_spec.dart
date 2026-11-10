/// 单文件整包公开资源目录的共享形状。
///
/// 词典与发音库都按「一个 resourceId 对应一个只含单个文件的公开资源规格」分发，
/// 归档文件名、整包 SHA-256、预计字节数与下载 URI 的读取语义完全一致，集中在此
/// 避免两个目录各写一份相同代理。资源身份（repository/revision/layout/摘要）仍由
/// [AsrPublicResourceSpec] 单一定义。
library;

import 'asr/asr_model_catalog.dart'
    show AsrDownloadSource, AsrPublicResourceSpec;

/// 词典与发音库整包资源的公共托管仓库（HF dataset，public、非 gated）与固定
/// revision。2026-11-10 双源独立下载核对通过：huggingface.co 与 hf-mirror.com
/// 在同一 revision 返回逐字节一致的整包。
const dictionaryPronunciationPublicRepository = 'banko3/loop-back';
const dictionaryPronunciationPublicRevision =
    '3b3a5bef53a1c2c86f72117a8ce149554122baac';

/// 单文件整包公开资源：resourceId 与只含单个文件的公开资源规格。
class SingleFileArchiveSpec {
  const SingleFileArchiveSpec({
    required this.resourceId,
    required this.resource,
  });

  /// 安装清单里的稳定资源身份（不随下载来源变化）。
  final String resourceId;

  /// 固定公开资源身份（repository/revision/layout/license/整包文件）。
  final AsrPublicResourceSpec resource;

  /// 归档文件名（公开资源目录里唯一的整包文件）。
  String get archiveFileName => resource.files.single.name;

  /// 整包 SHA-256（独立下载核对后记录，安装时校验）。
  String get archiveSha256 => resource.files.single.sha256;

  /// 预计下载字节数（整包）。
  int get estimatedDownloadBytes => resource.estimatedDownloadBytes;

  /// 指定下载源下的归档 URI。主源与镜像只换域名，路径与摘要不变。
  Uri fileUri(AsrDownloadSource source) =>
      resource.fileUri(source, resource.files.single);
}
