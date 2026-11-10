/// Piper VITS 音色目录（9 个 medium 单说话人模型）。
///
/// 与 Kokoro 根本不同：Piper 每个音色 = 一个**独立单说话人模型**（一个 `.onnx`），
/// 故音色既是「选择项」也是「下载单元」——每个音色单独下载、互不共享，合成时固定
/// `sid=0`（换音色需重建 `OfflineTts`，见 `piper_synthesizer.dart`）。
///
/// [PiperVoice.id] 同时作为：① 本地模型目录名；② 缓存键 voiceId（见
/// [TtsSpeechConfig.voiceId]）；③ 下载状态机的 key（见 `piper_model_provider.dart`）。
///
/// 公开源为 csukuangfj 的逐音色 HF 仓库（4 个与现有安装逐字节一致的音色）与
/// `iron6909/loop-back-models` 的重打包资产（ryan/joe/hfc_female 三个音色，其
/// HF 仓库 onnx 为旧版、与现有安装不一致）。lessac/alan 两个音色许可不允许
/// 再分发，仅保留目录身份、不提供下载。逐音色许可与核验见
/// `docs/features/20261110-tts-provider-decoupling/public-source-verification.md`。
library;

import '../asr/asr_model_catalog.dart'
    show AsrPublicResourceLayout, AsrPublicResourceSpec, AsrResourceFile;
import 'tts_engine.dart' show TtsAccent;
import 'tts_shared_resource_catalog.dart'
    show
        ttsEspeakNgDataResource,
        ttsEspeakNgDataResourceId,
        ttsPublicRepository,
        ttsPublicRevision;

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

/// 构造 GitHub 重打包整包形态的 Piper 音色资源（归档自带 espeak，依赖用于只补）。
AsrPublicResourceSpec _githubPiperSpec({
  required String id,
  required String archiveName,
  required String sha256,
  required int sizeBytes,
  required String license,
}) {
  return AsrPublicResourceSpec(
    id: id,
    repository: ttsPublicRepository,
    revision: ttsPublicRevision,
    layout: AsrPublicResourceLayout.githubReleaseAsset,
    license: license,
    files: [
      AsrResourceFile(name: archiveName, sha256: sha256, sizeBytes: sizeBytes),
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
    this.resource,
  });

  /// 音色标识（如 `en_US-amy-medium`）：本地目录名 + 缓存 voiceId + 下载 key。
  final String id;

  /// 展示名（如 `Amy`）。
  final String displayName;

  /// 口音（美/英），决定语言标签与分组。
  final TtsAccent accent;

  /// 是否女声（仅用于 UI 性别标签）。
  final bool isFemale;

  /// 逐音色许可字符串（以 rhasspy/piper-voices 的 LICENSE/MODEL_CARD 为准）。
  final String license;

  /// 固定公开资源身份；许可不允许再分发的音色为 null（不提供下载）。
  final AsrPublicResourceSpec? resource;

  /// 是否允许下载（许可允许再分发）。
  bool get redistributable => resource != null;

  /// 预计下载字节数（供下载弹窗预估）。
  ///
  /// HF 逐文件音色单独下载共享 espeak 依赖，预估需把该依赖一并计入；GitHub
  /// 整包音色归档自带 espeak，不重复计入。不可再分发音色返回 0。
  int get estimatedDownloadBytes {
    final resource = this.resource;
    if (resource == null) return 0;
    if (resource.layout != AsrPublicResourceLayout.huggingFaceResolve) {
      return resource.estimatedDownloadBytes;
    }
    return resource.estimatedDownloadBytes +
        ttsEspeakNgDataResource.estimatedDownloadBytes;
  }

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

/// 全部 9 个 Piper 音色（6 美音 + 3 英音）。
///
/// lessac/alan 许可不允许再分发（[PiperVoice.resource] 为 null），仅保留目录身份：
/// 已安装的旧目录继续识别与使用，但不再提供公开下载。
final List<PiperVoice> piperVoices = [
  // 美音（en_US）
  PiperVoice(
    id: 'en_US-amy-medium',
    displayName: 'Amy',
    accent: TtsAccent.us,
    isFemale: true,
    license: 'CC BY-SA 4.0',
    resource: _hfPiperSpec(
      id: 'en_US-amy-medium',
      repository: 'csukuangfj/vits-piper-en_US-amy-medium',
      revision: '79936839cc9409b1a752a45c629fe21639e1c1b2',
      license: 'CC BY-SA 4.0',
      onnxName: 'en_US-amy-medium.onnx',
      onnxSha256:
          'fbaa8e36d8f26fe6f3ebb65cab461e629d8b37a5b7c5fb78fb64317db73e1c25',
      onnxSizeBytes: 63201425,
      tokensSha256:
          '87c8ef66eae5473ed0cc0366b3964c736ca6c5f676c979522ea31234e47430b9',
      tokensSizeBytes: 921,
    ),
  ),
  PiperVoice(
    id: 'en_US-lessac-medium',
    displayName: 'Lessac',
    accent: TtsAccent.us,
    isFemale: true,
    license: 'Blizzard 2013 Research Licence (redistribution not permitted)',
  ),
  PiperVoice(
    id: 'en_US-ryan-medium',
    displayName: 'Ryan',
    accent: TtsAccent.us,
    isFemale: false,
    license: 'CC BY-NC-SA 4.0',
    resource: _githubPiperSpec(
      id: 'en_US-ryan-medium',
      archiveName: 'vits-piper-en_US-ryan-medium.tar.gz',
      sha256:
          '0cc1c5241f1651b5f893d3259dcd6a9c88acaeb33a59563a0ca1c113ef32c11e',
      sizeBytes: 67370820,
      license: 'CC BY-NC-SA 4.0',
    ),
  ),
  PiperVoice(
    id: 'en_US-joe-medium',
    displayName: 'Joe',
    accent: TtsAccent.us,
    isFemale: false,
    license: 'CC0',
    resource: _githubPiperSpec(
      id: 'en_US-joe-medium',
      archiveName: 'vits-piper-en_US-joe-medium.tar.gz',
      sha256:
          'b8c9581a93b02c67066aad978b6eee56e247c692f82572da00e7b998a13ce38f',
      sizeBytes: 67329430,
      license: 'CC0',
    ),
  ),
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
      tokensSha256:
          'ef3a7e4a8d1af0c9d4dc45aaae1a6242ebe24a7ed6f3d025a49eb29682784c6d',
      tokensSizeBytes: 940,
    ),
  ),
  PiperVoice(
    id: 'en_US-hfc_female-medium',
    displayName: 'Hannah',
    accent: TtsAccent.us,
    isFemale: true,
    license: 'CC BY-NC-SA 4.0',
    resource: _githubPiperSpec(
      id: 'en_US-hfc_female-medium',
      archiveName: 'vits-piper-en_US-hfc_female-medium.tar.gz',
      sha256:
          'f4dd17d8d1e392df7691a6acb4402e93cb284b935e1cd1e9b86bf108707be784',
      sizeBytes: 67359748,
      license: 'CC BY-NC-SA 4.0',
    ),
  ),
  // 英音（en_GB）
  PiperVoice(
    id: 'en_GB-alan-medium',
    displayName: 'Alan',
    accent: TtsAccent.uk,
    isFemale: false,
    license: 'All Rights Reserved (redistribution not permitted)',
  ),
  PiperVoice(
    id: 'en_GB-cori-medium',
    displayName: 'Cori',
    accent: TtsAccent.uk,
    isFemale: true,
    license: 'CC BY 4.0',
    resource: _hfPiperSpec(
      id: 'en_GB-cori-medium',
      repository: 'csukuangfj/vits-piper-en_GB-cori-medium',
      revision: 'e304c95c578725ba9cab0cff451c4e5d9aaf889e',
      license: 'CC BY 4.0',
      onnxName: 'en_GB-cori-medium.onnx',
      onnxSha256:
          '8b0d3cdd77f2878e0aa2048103eabb4d01b334783f99629f042bcf703aeba487',
      onnxSizeBytes: 63531507,
      tokensSha256:
          'ef3a7e4a8d1af0c9d4dc45aaae1a6242ebe24a7ed6f3d025a49eb29682784c6d',
      tokensSizeBytes: 940,
    ),
  ),
  PiperVoice(
    id: 'en_GB-alba-medium',
    displayName: 'Alba',
    accent: TtsAccent.uk,
    isFemale: true,
    license: 'CC BY 4.0',
    resource: _hfPiperSpec(
      id: 'en_GB-alba-medium',
      repository: 'csukuangfj/vits-piper-en_GB-alba-medium',
      revision: '7e469a54c7a4f5bd191cae788e197266e2c9c5ac',
      license: 'CC BY 4.0',
      onnxName: 'en_GB-alba-medium.onnx',
      onnxSha256:
          'c904d007a8047ab13628b021351b983d0a2627c0d7a81c64a6fe9ad661adb1cf',
      onnxSizeBytes: 63201430,
      tokensSha256:
          '87c8ef66eae5473ed0cc0366b3964c736ca6c5f676c979522ea31234e47430b9',
      tokensSizeBytes: 921,
    ),
  ),
];

/// 美音默认音色。
const String piperDefaultVoiceUs = 'en_US-amy-medium';

/// 英音默认音色（alan 因许可不允许再分发，改为 CC BY 4.0 的 cori）。
const String piperDefaultVoiceUk = 'en_GB-cori-medium';

/// 全部 Piper 公开资源（7 个可下载音色 + 共享 espeak-ng-data）。
final piperPublicResourceCatalog = <String, AsrPublicResourceSpec>{
  for (final voice in piperVoices)
    if (voice.resource != null) voice.id: voice.resource!,
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
