/// 内置离线词典资源目录。
///
/// 词典资源随 App 版本发布：更新词典时先上传新的 ZIP，再同步修改此文件中的
/// resourceId、SHA-256 与公开源 revision。运行中的 App 不通过远程 manifest 检查更新。
library;

// 复用 ASR 已落地的公开资源描述（AsrPublicResourceSpec 等），与语音识别/TTS 保持
// 同一实现先例，不另起一套词典版本；单文件整包的共享形状与托管仓库常量见
// resource_archive_spec.dart。
import '../asr/asr_model_catalog.dart'
    show AsrPublicResourceLayout, AsrPublicResourceSpec, AsrResourceFile;
import '../resource_archive_spec.dart';

/// 词典数据来源与许可：ECDICT 筛选子集，MIT 许可。
const dictionaryDataLicense = 'ECDICT (MIT)';

/// 单个离线词典 ZIP 资源规格，归档文件位于固定公开源。
class DictionarySpec extends SingleFileArchiveSpec {
  const DictionarySpec({
    required this.nativeLanguage,
    required super.resourceId,
    required super.resource,
  });

  final String nativeLanguage;

  /// 数据来源与许可标注。
  String get license => resource.license;
}

/// 当前发布的离线词典资源。
const dictionarySpecs = <String, DictionarySpec>{
  'zh-CN': DictionarySpec(
    nativeLanguage: 'zh-CN',
    resourceId: 'dict-en_zh-CN-v1',
    resource: AsrPublicResourceSpec(
      id: 'dict-en_zh-CN-v1',
      repository: dictionaryPronunciationPublicRepository,
      revision: dictionaryPronunciationPublicRevision,
      layout: AsrPublicResourceLayout.huggingFaceDatasetResolve,
      license: dictionaryDataLicense,
      files: [
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
      repository: dictionaryPronunciationPublicRepository,
      revision: dictionaryPronunciationPublicRevision,
      layout: AsrPublicResourceLayout.huggingFaceDatasetResolve,
      license: dictionaryDataLicense,
      files: [
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
