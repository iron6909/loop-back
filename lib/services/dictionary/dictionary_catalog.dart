/// 内置离线词典资源目录。
///
/// 词典资源随 App 版本发布：更新词典时先上传新的 ZIP，再同步修改此文件中的
/// resourceId、SHA-256 与公开源 revision。运行中的 App 不通过远程 manifest 检查更新。
library;

// 复用语音识别已落地的下载来源枚举：主源与镜像只改变域名，不改变被信任的
// 版本与摘要。词典是 HF dataset，URL 需带 /datasets/ 段，故由本目录自行拼接。
import '../asr/asr_model_catalog.dart' show AsrDownloadSource;

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
    required this.archiveFileName,
    required this.archiveSha256,
    required this.estimatedDownloadBytes,
    this.license = dictionaryDataLicense,
  });

  final String nativeLanguage;
  final String resourceId;

  /// 公开源仓库内的归档文件名。
  final String archiveFileName;

  /// 整包 SHA-256（独立下载核对后记录，安装时校验）。
  final String archiveSha256;

  /// 公开源压缩包的预计下载大小（字节），用于展示或后续下载策略。
  final int estimatedDownloadBytes;

  /// 数据来源与许可标注。
  final String license;

  /// 指定下载源下的归档 URI。主源与镜像只改变域名，不改变资源身份与摘要。
  Uri fileUri(AsrDownloadSource source) {
    return Uri.parse(
      '${source.host}/datasets/$dictionaryPublicRepository/resolve/'
      '$dictionaryPublicRevision/$archiveFileName',
    );
  }
}

/// 当前发布的离线词典资源。
const dictionarySpecs = <String, DictionarySpec>{
  'zh-CN': DictionarySpec(
    nativeLanguage: 'zh-CN',
    resourceId: 'dict-en_zh-CN-v1',
    archiveFileName: 'dict_en_zh-CN-v1.sqlite.zip',
    archiveSha256:
        '2acfc22aae4658b707973c508e1356d4c8ce4bc07c502c6d2c3030a95bc5f5e9',
    estimatedDownloadBytes: 12552930,
  ),
  'zh-TW': DictionarySpec(
    nativeLanguage: 'zh-TW',
    resourceId: 'dict-en_zh-TW-v1',
    archiveFileName: 'dict_en_zh-TW-v1.sqlite.zip',
    archiveSha256:
        'dee7bc7d6ec43f88371d17a6a2595d277172a8897d70ff9a280a5ef8142d4cac',
    estimatedDownloadBytes: 12552893,
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
