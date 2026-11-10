/// Kokoro TTS 音色目录。
///
/// sherpa-onnx `kokoro-en-v0_19` 模型的 11 个英文发音人。发音人的口音由命名前缀
/// 编码：`a*`=美音、`b*`=英音；`*f_`=女声、`*m_`=男声。合成时按 [KokoroVoice.sid]
/// 指定发音人（传给 `OfflineTts.generate(sid:)`），[KokoroVoice.id] 用作缓存键的
/// voiceId（见 [TtsSpeechConfig.voiceId]）。
library;

import 'tts_engine.dart';

/// 单个 Kokoro 发音人。
class KokoroVoice {
  /// 发音人标识（如 `af_sarah`），同时作为缓存 voiceId。
  final String id;

  /// 模型内的发音人序号（传给 `OfflineTts.generate(sid:)`）。
  final int sid;

  /// 展示名（如 `Sarah`）。
  final String displayName;

  const KokoroVoice({
    required this.id,
    required this.sid,
    required this.displayName,
  });

  /// 口音：`a*`=美音，`b*`=英音（由 id 前缀推导）。
  TtsAccent get accent => id.startsWith('b') ? TtsAccent.uk : TtsAccent.us;

  /// 是否女声：`*f_`=女声，`*m_`=男声（由 id 第二个字符推导）。
  bool get isFemale => id.length > 1 && id[1] == 'f';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KokoroVoice &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          sid == other.sid &&
          displayName == other.displayName;

  @override
  int get hashCode => Object.hash(id, sid, displayName);
}

/// 全部 11 个 Kokoro 发音人（sid 与模型 `voices.bin` 内顺序严格一致）。
const List<KokoroVoice> kokoroVoices = [
  // 美音（af_/am_）
  KokoroVoice(id: 'af', sid: 0, displayName: 'Default'),
  KokoroVoice(id: 'af_bella', sid: 1, displayName: 'Bella'),
  KokoroVoice(id: 'af_nicole', sid: 2, displayName: 'Nicole'),
  KokoroVoice(id: 'af_sarah', sid: 3, displayName: 'Sarah'),
  KokoroVoice(id: 'af_sky', sid: 4, displayName: 'Sky'),
  KokoroVoice(id: 'am_adam', sid: 5, displayName: 'Adam'),
  KokoroVoice(id: 'am_michael', sid: 6, displayName: 'Michael'),
  // 英音（bf_/bm_）
  KokoroVoice(id: 'bf_emma', sid: 7, displayName: 'Emma'),
  KokoroVoice(id: 'bf_isabella', sid: 8, displayName: 'Isabella'),
  KokoroVoice(id: 'bm_george', sid: 9, displayName: 'George'),
  KokoroVoice(id: 'bm_lewis', sid: 10, displayName: 'Lewis'),
];

/// 美音默认音色（`af_sarah`）。
const String kokoroDefaultVoiceUs = 'af_sarah';

/// 英音默认音色（`bf_emma`）。
const String kokoroDefaultVoiceUk = 'bf_emma';

/// 返回指定口音下的全部发音人。
List<KokoroVoice> voicesForAccent(TtsAccent accent) =>
    kokoroVoices.where((v) => v.accent == accent).toList(growable: false);

/// 按 id 查找发音人；未知 id 返回 null。
KokoroVoice? voiceById(String id) {
  for (final v in kokoroVoices) {
    if (v.id == id) return v;
  }
  return null;
}

/// 指定口音的默认发音人。
KokoroVoice defaultVoice(TtsAccent accent) {
  final id = accent == TtsAccent.uk
      ? kokoroDefaultVoiceUk
      : kokoroDefaultVoiceUs;
  return voiceById(id)!;
}

/// 把 voiceId 解析为合成用的 sid；未知 id 回退到该口音默认音色。
///
/// [fallbackAccent] 在 [voiceId] 无法识别时决定回退到哪个口音的默认音色。
int sidForVoiceId(String? voiceId, {required TtsAccent fallbackAccent}) {
  if (voiceId != null) {
    final v = voiceById(voiceId);
    if (v != null) return v.sid;
  }
  return defaultVoice(fallbackAccent).sid;
}
