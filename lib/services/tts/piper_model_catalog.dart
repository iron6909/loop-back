/// Piper VITS 音色目录（7 个单说话人模型）。
///
/// 与 Kokoro 根本不同：Piper 每个音色 = 一个**独立单说话人模型**（一个 `.onnx`），
/// 故音色既是「选择项」也是「下载单元」——每个音色单独下载、互不共享，合成时固定
/// `sid=0`（换音色需重建 `OfflineTts`，见 `piper_synthesizer.dart`）。
///
/// [PiperVoice.id] 同时作为：① 本地模型目录名；② 缓存键 voiceId（见
/// [TtsSpeechConfig.voiceId]）；③ 下载状态机的 key（见 `piper_model_provider.dart`）。
///
/// 选音色只按**许可**筛：本目录里除 `en_GB-northern_english_male-medium`（CC-BY-SA 4.0）
/// 外全部是 public domain。许可不明（amy/danny/kusal/arctic/jenny）、非商用
/// （ryan/hfc_female/l2arctic/semaine/miro/dii）与 only-research（lessac/alan）
/// 一律不进目录；CC BY 4.0 的 alba/cori-medium 按其「仅收录 A 档」的决策也一并移除。
/// 许可以 `rhasspy/piper-voices` 每个音色目录的 `MODEL_CARD` 为准。
///
/// 全部音色均从 csukuangfj 的逐音色 HF 仓库下载（onnx + tokens.txt），不再依赖本
/// 项目自建 GitHub 发布资产。已移除音色见 [removedPiperVoiceIds]，启动迁移清理其
/// 孤儿安装目录并回退存量偏好。
library;

import '../asr/asr_model_catalog.dart'
    show AsrPublicResourceLayout, AsrPublicResourceSpec, AsrResourceFile;
import 'tts_engine.dart' show TtsAccent;
import 'tts_shared_resource_catalog.dart'
    show ttsEspeakNgDataResource, ttsEspeakNgDataResourceId;

/// Piper 推理所需的固定文件名。
const piperTokensFileName = 'tokens.txt';
const piperDataDirectoryName = 'espeak-ng-data';

/// 构造 HF resolve 形态的 Piper 音色资源：onnx + tokens，共享 espeak 依赖。
AsrPublicResourceSpec _hfPiperSpec({
  required String id,
  required String repository,
  required String revision,
  required String license,
  required String onnxName,
  required String onnxSha256,
  required int onnxSizeBytes,
  required String tokensSha256,
  required int tokensSizeBytes,
}) {
  return AsrPublicResourceSpec(
    id: id,
    repository: repository,
    revision: revision,
    layout: AsrPublicResourceLayout.huggingFaceResolve,
    license: license,
    files: [
      AsrResourceFile(
        name: onnxName,
        sha256: onnxSha256,
        sizeBytes: onnxSizeBytes,
      ),
      AsrResourceFile(
        name: piperTokensFileName,
        sha256: tokensSha256,
        sizeBytes: tokensSizeBytes,
      ),
    ],
    dependencies: const [ttsEspeakNgDataResourceId],
  );
}

/// 单个 Piper 音色（= 一个独立模型）。
class PiperVoice {
  const PiperVoice({
    required this.id,
    required this.displayName,
    required this.accent,
    required this.isFemale,
    required this.license,
    required this.resource,
  });

  /// 音色标识（如 `en_US-kristin-medium`）：本地目录名 + 缓存 voiceId + 下载 key。
  final String id;

  /// 展示名（如 `Kristin`）。
  final String displayName;

  /// 口音（美/英），决定语言标签与分组。
  final TtsAccent accent;

  /// 是否女声（仅用于 UI 性别标签）。
  final bool isFemale;

  /// 逐音色许可字符串（以 rhasspy/piper-voices 的 LICENSE/MODEL_CARD 为准）。
  final String license;

  /// 固定公开资源身份；所有音色均有公开资源、可下载。
  final AsrPublicResourceSpec resource;

  /// 预计下载字节数（供下载弹窗预估）。
  ///
  /// 模型与 `tokens.txt` 逐文件下载，共享 `espeak-ng-data` 依赖需一并计入。
  int get estimatedDownloadBytes =>
      resource.estimatedDownloadBytes +
      ttsEspeakNgDataResource.estimatedDownloadBytes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PiperVoice &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          displayName == other.displayName &&
          accent == other.accent &&
          isFemale == other.isFemale &&
          license == other.license &&
          resource == other.resource;

  @override
  int get hashCode =>
      Object.hash(id, displayName, accent, isFemale, license, resource);
}

/// 全英音色共用的 `tokens.txt` 身份（en_US / en_GB 的 espeak 音素表一致）。
const _piperTokensMediumSha256 =
    'ef3a7e4a8d1af0c9d4dc45aaae1a6242ebe24a7ed6f3d025a49eb29682784c6d';
const _piperTokensMediumSizeBytes = 940;

/// 全部 7 个 Piper 音色（5 美音 + 2 英音），均可公开下载。
///
/// 男女与口音分布：美男 3 / 美女 2 / 英女 1 / 英男 1。
final List<PiperVoice> piperVoices = [
  // 美音（en_US）男声
  PiperVoice(
    id: 'en_US-bryce-medium',
    displayName: 'Bryce',
    accent: TtsAccent.us,
    isFemale: false,
    license: 'public domain',
    resource: _hfPiperSpec(
      id: 'en_US-bryce-medium',
      repository: 'csukuangfj/vits-piper-en_US-bryce-medium',
      revision: 'b7f24892d9291522cf27e7cbfe34f17fa1cf4b17',
      license: 'public domain',
      onnxName: 'en_US-bryce-medium.onnx',
      onnxSha256:
          'f9ad3c773102fc27b13f48e5a743bbc75de6036b07dfb8a5c84ec2cc24153a28',
      onnxSizeBytes: 63531507,
      tokensSha256: _piperTokensMediumSha256,
      tokensSizeBytes: _piperTokensMediumSizeBytes,
    ),
  ),
  PiperVoice(
    id: 'en_US-john-medium',
    displayName: 'John',
    accent: TtsAccent.us,
    isFemale: false,
    license: 'public domain',
    resource: _hfPiperSpec(
      id: 'en_US-john-medium',
      repository: 'csukuangfj/vits-piper-en_US-john-medium',
      revision: 'adfff0e2951b85fafe20b582a8961a956ba926bd',
      license: 'public domain',
      onnxName: 'en_US-john-medium.onnx',
      onnxSha256:
          '7ab60237f77e06c8f32b811080b7ad82d23bc5bacc4bba2c35e58aeae6833364',
      onnxSizeBytes: 63531507,
      tokensSha256: _piperTokensMediumSha256,
      tokensSizeBytes: _piperTokensMediumSizeBytes,
    ),
  ),
  PiperVoice(
    id: 'en_US-norman-medium',
    displayName: 'Norman',
    accent: TtsAccent.us,
    isFemale: false,
    license: 'public domain',
    resource: _hfPiperSpec(
      id: 'en_US-norman-medium',
      repository: 'csukuangfj/vits-piper-en_US-norman-medium',
      revision: '96632d35050997005e69857cbdf5352ed329bb45',
      license: 'public domain',
      onnxName: 'en_US-norman-medium.onnx',
      onnxSha256:
          'fa06b6b8b280e176b17f8424e05ca12d0223eeac9a31c87230937fe7120fbe2a',
      onnxSizeBytes: 63531507,
      tokensSha256: _piperTokensMediumSha256,
      tokensSizeBytes: _piperTokensMediumSizeBytes,
    ),
  ),
  // 美音（en_US）女声
  PiperVoice(
    id: 'en_US-kristin-medium',
    displayName: 'Kristin',
    accent: TtsAccent.us,
    isFemale: true,
    license: 'public domain',
    resource: _hfPiperSpec(
      id: 'en_US-kristin-medium',
      repository: 'csukuangfj/vits-piper-en_US-kristin-medium',
      revision: '6fdc68249ba2b1b41c1c42ec74341d1599e2c96e',
      license: 'public domain',
      onnxName: 'en_US-kristin-medium.onnx',
      onnxSha256:
          'f9a5c375c70ddc33ccdb3969c76a4d7cc5255ac08119a312b0034a1d07041be6',
      onnxSizeBytes: 63531507,
      tokensSha256: _piperTokensMediumSha256,
      tokensSizeBytes: _piperTokensMediumSizeBytes,
    ),
  ),
  PiperVoice(
    id: 'en_US-ljspeech-medium',
    displayName: 'Linda',
    accent: TtsAccent.us,
    isFemale: true,
    license: 'public domain',
    resource: _hfPiperSpec(
      id: 'en_US-ljspeech-medium',
      repository: 'csukuangfj/vits-piper-en_US-ljspeech-medium',
      revision: '34f390d13b9edbaa30c339127de0f9c4c5948c90',
      license: 'public domain',
      onnxName: 'en_US-ljspeech-medium.onnx',
      onnxSha256:
          '8ceba58a4b540d4e7e7e24ad079cf0d92762a4fd334e059f12940787c6c37b3d',
      onnxSizeBytes: 63531507,
      tokensSha256: _piperTokensMediumSha256,
      tokensSizeBytes: _piperTokensMediumSizeBytes,
    ),
  ),
  // 英音（en_GB）女声
  PiperVoice(
    id: 'en_GB-cori-high',
    displayName: 'Cori',
    accent: TtsAccent.uk,
    isFemale: true,
    license: 'public domain',
    resource: _hfPiperSpec(
      id: 'en_GB-cori-high',
      repository: 'csukuangfj/vits-piper-en_GB-cori-high',
      revision: '37f6efb503f5dc22de01bad04c9a118a99111096',
      license: 'public domain',
      onnxName: 'en_GB-cori-high.onnx',
      onnxSha256:
          '006bb4db48e066f7f1be91d218db3b76617a707196271694ca6455d7bbd13842',
      onnxSizeBytes: 114219480,
      tokensSha256: _piperTokensMediumSha256,
      tokensSizeBytes: _piperTokensMediumSizeBytes,
    ),
  ),
  // 英音（en_GB）男声（CC-BY-SA 4.0，原样分发需署名）
  PiperVoice(
    id: 'en_GB-northern_english_male-medium',
    displayName: 'Northern',
    accent: TtsAccent.uk,
    isFemale: false,
    license: 'CC BY-SA 4.0',
    resource: _hfPiperSpec(
      id: 'en_GB-northern_english_male-medium',
      repository: 'csukuangfj/vits-piper-en_GB-northern_english_male-medium',
      revision: '1d9a616e1cdeb91d8bc0b921a8b31296e2c9ff75',
      license: 'CC BY-SA 4.0',
      onnxName: 'en_GB-northern_english_male-medium.onnx',
      onnxSha256:
          'd23e7891af7062eb188283dba94866e25ffd5b01a0d9fb9a23c71a39b75b2308',
      onnxSizeBytes: 63201430,
      tokensSha256:
          '2619c1a9de1bcf928162f40c583caf39368cfd6b2340c7bcad51dc634411ec36',
      tokensSizeBytes: 907,
    ),
  ),
];

/// 美音默认音色（kristin，public domain）。
const String piperDefaultVoiceUs = 'en_US-kristin-medium';

/// 英音默认音色（cori-high，public domain）。
const String piperDefaultVoiceUk = 'en_GB-cori-high';

/// 历史版本里因许可不允许再分发而移除的音色 ID（lessac / alan）。
const removedPiperVoiceLessacId = 'en_US-lessac-medium';
const removedPiperVoiceAlanId = 'en_GB-alan-medium';

/// 本轮因许可收紧（只保留 A 档）而下线的音色 ID。
///
/// - `amy` 许可不明；`joe` 为 CC0 但此前只从自建 GitHub 资产分发；
/// - `ryan` / `hfc_female` 为 CC BY-NC-SA 4.0（非商用）；
/// - `cori-medium` / `alba` 为 CC BY 4.0（B 档），按只保留 A 档的决策下线。
const retiredPiperVoiceIds = [
  'en_US-amy-medium',
  'en_US-ryan-medium',
  'en_US-joe-medium',
  'en_US-hfc_female-medium',
  'en_GB-cori-medium',
  'en_GB-alba-medium',
];

/// 全部已移除音色 ID；启动迁移据此清理孤儿安装目录并回退存量偏好。
const removedPiperVoiceIds = [
  removedPiperVoiceLessacId,
  removedPiperVoiceAlanId,
  ...retiredPiperVoiceIds,
];

/// 全部 Piper 公开资源（7 个可下载音色 + 共享 espeak-ng-data）。
final piperPublicResourceCatalog = <String, AsrPublicResourceSpec>{
  for (final voice in piperVoices) voice.id: voice.resource,
  ttsEspeakNgDataResourceId: ttsEspeakNgDataResource,
};

/// 按 id 查找音色；未知 id 返回 null。
PiperVoice? piperVoiceById(String id) {
  for (final v in piperVoices) {
    if (v.id == id) return v;
  }
  return null;
}

/// 返回指定口音下的全部音色。
List<PiperVoice> piperVoicesByAccent(TtsAccent accent) =>
    piperVoices.where((v) => v.accent == accent).toList(growable: false);

/// 指定口音的默认音色。
PiperVoice piperDefaultVoice(TtsAccent accent) {
  final id = accent == TtsAccent.uk ? piperDefaultVoiceUk : piperDefaultVoiceUs;
  return piperVoiceById(id) ?? piperVoices.first;
}
