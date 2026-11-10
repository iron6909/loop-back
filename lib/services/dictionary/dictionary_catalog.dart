/// 内置离线词典资源目录。
///
/// 词典资源随 App 版本发布：更新词典时先上传新的 ZIP，再同步修改此文件中的
/// resourceId、SHA-256 与公开源 revision。运行中的 App 不通过远程 manifest 检查更新。
library;

// 复用 ASR 已落地的公开资源描述（AsrDownloadSource/AsrPublicResourceSpec 等），
// 与语音识别/TTS 保持同一实现先例，不另起一套词典版本。
import '../asr/asr_model_catalog.dart'
    show
        AsrDownloadSource,
        AsrPublicResourceLayout,
        AsrPublicResourceSpec,
        AsrResourceFile;

/// 词典公开源仓库（HF dataset，public、非 gated）。
const dictionaryPublicRepository = 'banko3/loop-back';

/// 固定 revision。2026-11-10 双源独立下载核对通过：huggingface.co 与
/// hf-mirror.com 在同一 revision 返回与旧 CDN 归档逐字节一致的整包。
const dictionaryPublicRevision = '3b3a5bef53a1c2c86f72117a8ce149554122baac';

/// 词典数据来源与许可：ECDICT 筛选子集，MIT 许可。
const dictionaryDataLicense = 'ECDICT (MIT)';

/// 单个离线词典 ZIP 资源规格，归档文件位于固定公开源。
class DictionarySpec {
  const DictionarySpec({
    required this.nativeLanguage,
    required this.resourceId,
    required this.resource,
  });

  final String nativeLanguage;

  /// 安装清单里的稳定资源身份（不随下载来源变化）。
  final String resourceId;

  /// 固定公开资源身份（repository/revision/layout/license/整包文件）。
  final AsrPublicResourceSpec resource;

  /// 公开源仓库内的归档文件名。
  String get archiveFileName => resource.files.single.name;

  /// 整包 SHA-256（独立下载核对后记录，安装时校验）。
  String get archiveSha256 => resource.files.single.sha256;

  /// 公开源压缩包的预计下载大小（字节），用于展示或后续下载策略。
  int get estimatedDownloadBytes => resource.estimatedDownloadBytes;

  /// 数据来源与许可标注。
  String get license => resource.license;

  /// 指定下载源下的归档 URI。主源与镜像只改变域名，不改变资源身份与摘要。
  Uri fileUri(AsrDownloadSource source) =>
      resource.fileUri(source, resource.files.single);
}

/// 当前发布的离线词典资源。
final dictionarySpecs = <String, DictionarySpec>{
  'zh-CN': DictionarySpec(
    nativeLanguage: 'zh-CN',
    resourceId: 'dict-en_zh-CN-v1',
    resource: AsrPublicResourceSpec(
      id: 'dict-en_zh-CN-v1',
      repository: dictionaryPublicRepository,
      revision: dictionaryPublicRevision,
      layout: AsrPublicResourceLayout.huggingFaceDatasetResolve,
      license: dictionaryDataLicense,
      files: const [
        AsrResourceFile(
          name: 'dict_en_zh-CN-v1.sqlite.zip',
          sha256:
              '2acfc22aae4658b707973c508e1356d4c8ce4bc07c502c6d2c3030a95bc5f5e9',
          sizeBytes: 12552930,
        ),
      ],
    ),
  ),
  'zh-TW': DictionarySpec(
    nativeLanguage: 'zh-TW',
    resourceId: 'dict-en_zh-TW-v1',
    resource: AsrPublicResourceSpec(
      id: 'dict-en_zh-TW-v1',
      repository: dictionaryPublicRepository,
      revision: dictionaryPublicRevision,
      layout: AsrPublicResourceLayout.huggingFaceDatasetResolve,
      license: dictionaryDataLicense,
      files: const [
        AsrResourceFile(
          name: 'dict_en_zh-TW-v1.sqlite.zip',
          sha256:
              'dee7bc7d6ec43f88371d17a6a2595d277172a8897d70ff9a280a5ef8142d4cac',
          sizeBytes: 12552893,
        ),
      ],
    ),
  ),
};

/// 返回指定母语的内置词典规格。
DictionarySpec dictionarySpecOf(String nativeLanguage) {
  final spec = dictionarySpecs[nativeLanguage];
  if (spec == null) {
    throw ArgumentError.value(nativeLanguage, 'nativeLanguage');
  }
  return spec;
}
