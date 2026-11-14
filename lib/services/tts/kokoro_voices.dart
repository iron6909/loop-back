/// Kokoro TTS 音色目录。
///
/// 对应 Kokoro v1.0 多语言模型（`kokoro-multi-lang-v1_0`）中的 **28 个英语发音人**
/// （美音 sid 0..19、英音 sid 20..27），sid 以 sherpa-onnx 文档的 speaker ID 表为准。
/// 模型里另有 25 个西/法/印地/意/日/葡/中母语音色，本项目只合成英文，故不收录。
///
/// 发音人的口音由命名前缀编码：`a*`=美音、`b*`=英音；`*f_`=女声、`*m_`=男声。
/// 合成时按 [KokoroVoice.sid] 指定发音人（传给 `OfflineTts.generate(sid:)`），
/// [KokoroVoice.id] 用作缓存键的 voiceId（见 [TtsSpeechConfig.voiceId]）。
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

/// 全部 28 个英语 Kokoro 发音人（sid 与模型 `voices.bin` 内顺序严格一致）。
///
/// v0.19 的 `af`（默认女声）在 v1.0 不存在，已换成 `af_heart`；
/// 存量偏好里的 `af` 会由 [sidForVoiceId] 回退到该口音默认音色。
const List<KokoroVoice> kokoroVoices = [
  // 美音（af_/am_，sid 0..19）
  KokoroVoice(id: 'af_alloy', sid: 0, displayName: 'Alloy'),
  KokoroVoice(id: 'af_aoede', sid: 1, displayName: 'Aoede'),
  KokoroVoice(id: 'af_bella', sid: 2, displayName: 'Bella'),
  KokoroVoice(id: 'af_heart', sid: 3, displayName: 'Heart'),
  KokoroVoice(id: 'af_jessica', sid: 4, displayName: 'Jessica'),
  KokoroVoice(id: 'af_kore', sid: 5, displayName: 'Kore'),
  KokoroVoice(id: 'af_nicole', sid: 6, displayName: 'Nicole'),
  KokoroVoice(id: 'af_nova', sid: 7, displayName: 'Nova'),
  KokoroVoice(id: 'af_river', sid: 8, displayName: 'River'),
  KokoroVoice(id: 'af_sarah', sid: 9, displayName: 'Sarah'),
  KokoroVoice(id: 'af_sky', sid: 10, displayName: 'Sky'),
  KokoroVoice(id: 'am_adam', sid: 11, displayName: 'Adam'),
  KokoroVoice(id: 'am_echo', sid: 12, displayName: 'Echo'),
  KokoroVoice(id: 'am_eric', sid: 13, displayName: 'Eric'),
  KokoroVoice(id: 'am_fenrir', sid: 14, displayName: 'Fenrir'),
  KokoroVoice(id: 'am_liam', sid: 15, displayName: 'Liam'),
  KokoroVoice(id: 'am_michael', sid: 16, displayName: 'Michael'),
  KokoroVoice(id: 'am_onyx', sid: 17, displayName: 'Onyx'),
  KokoroVoice(id: 'am_puck', sid: 18, displayName: 'Puck'),
  KokoroVoice(id: 'am_santa', sid: 19, displayName: 'Santa'),
  // 英音（bf_/bm_，sid 20..27）
  KokoroVoice(id: 'bf_alice', sid: 20, displayName: 'Alice'),
  KokoroVoice(id: 'bf_emma', sid: 21, displayName: 'Emma'),
  KokoroVoice(id: 'bf_isabella', sid: 22, displayName: 'Isabella'),
  KokoroVoice(id: 'bf_lily', sid: 23, displayName: 'Lily'),
  KokoroVoice(id: 'bm_daniel', sid: 24, displayName: 'Daniel'),
  KokoroVoice(id: 'bm_fable', sid: 25, displayName: 'Fable'),
  KokoroVoice(id: 'bm_george', sid: 26, displayName: 'George'),
  KokoroVoice(id: 'bm_lewis', sid: 27, displayName: 'Lewis'),
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
