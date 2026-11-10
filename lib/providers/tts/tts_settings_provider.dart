/// 语音合成（TTS）设置 Provider
///
/// 全局控制 TTS 发音偏好：合成引擎（平台 TTS / Kokoro / Piper）与口音（美/英）。
/// 口音全局生效于所有发音场景（闪卡 / 收藏 / 词典单词 / 词典例句）。
///
/// 采用手动 Notifier 模式（对齐 [LearningSettings]）：`build()` 从
/// [initialTtsSettingsProvider] 同步读 SP 注入的快照，避免闪卡翻面等**同步**
/// 触发的发音路径在异步加载完成前读到默认口音。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/app_logger.dart';
import '../../services/asr/asr_model_catalog.dart' show AsrDownloadSource;
import '../../services/tts/kokoro_voices.dart';
import '../../services/tts/piper_model_catalog.dart';
import '../../services/tts/tts_engine.dart';

/// 同步从 SP 预读的 TTS 设置初值，由 main() 通过 override 注入。
///
/// 默认返回 [TtsSettings] 默认值（Kokoro + 美音）：发音是辅助功能，未注入时
/// 用默认值优雅降级，不让宿主页面（含发音按钮）因缺 override 而崩溃。
final initialTtsSettingsProvider = Provider<TtsSettings>((ref) {
  return const TtsSettings();
});

/// TTS 设置 SP key 常量。
abstract final class TtsSettingsKeys {
  static const engine = 'tts_engine';

  /// 历史版本写入的旧引擎值（'echoLoop'），读取时保留兼容。
  static const legacyTtsEngineValue = 'echoLoop';
  static const accent = 'tts_accent';
  static const kokoroVoiceUs = 'tts_kokoro_voice_us';
  static const kokoroVoiceUk = 'tts_kokoro_voice_uk';
  static const kokoroVariant = 'tts_kokoro_variant';
  static const piperVoiceUs = 'tts_piper_voice_us';
  static const piperVoiceUk = 'tts_piper_voice_uk';

  /// TTS 模型下载来源（公开上游 / hf-mirror 镜像）。
  static const downloadSource = 'tts_download_source';
}

/// 将所有平台历史写入的旧引擎值迁移为 Kokoro 实现名。
Future<void> migrateLegacyTtsPreference(SharedPreferences prefs) async {
  if (prefs.getString(TtsSettingsKeys.engine) !=
      TtsSettingsKeys.legacyTtsEngineValue) {
    return;
  }
  await prefs.setString(TtsSettingsKeys.engine, TtsEngineKind.kokoro.name);
}

/// 将 Android 历史系统 TTS 偏好迁移为 Kokoro。
///
/// 仅 Android 执行：iOS/macOS 仍可能合法使用平台 TTS，不能全平台迁移
/// [TtsEngineKind.platform]。
Future<void> migrateAndroidPlatformTtsPreference(
  SharedPreferences prefs,
) async {
  if (prefs.getString(TtsSettingsKeys.engine) != TtsEngineKind.platform.name) {
    return;
  }
  await prefs.setString(TtsSettingsKeys.engine, TtsEngineKind.kokoro.name);
}

/// TTS 设置不可变值对象。
class TtsSettings {
  /// 合成引擎（默认 Kokoro）。
  final TtsEngineKind engine;

  /// 发音口音（默认美音）。
  final TtsAccent accent;

  /// Kokoro 美音音色 id（默认 [kokoroDefaultVoiceUs]）。
  final String kokoroVoiceUs;

  /// Kokoro 英音音色 id（默认 [kokoroDefaultVoiceUk]）。
  final String kokoroVoiceUk;

  /// Kokoro 选用的模型变体（默认 fp32，速度/效果最佳）。
  final KokoroModelVariant kokoroVariant;

  /// Piper 美音音色 id（默认 [piperDefaultVoiceUs]）。
  final String piperVoiceUs;

  /// Piper 英音音色 id（默认 [piperDefaultVoiceUk]）。
  final String piperVoiceUk;

  /// TTS 模型下载来源（仅影响后续安装，已安装模型不重下）。
  final AsrDownloadSource downloadSource;

  const TtsSettings({
    this.engine = TtsEngineKind.kokoro,
    this.accent = TtsAccent.us,
    this.kokoroVoiceUs = kokoroDefaultVoiceUs,
    this.kokoroVoiceUk = kokoroDefaultVoiceUk,
    this.kokoroVariant = KokoroModelVariant.fp32,
    this.piperVoiceUs = piperDefaultVoiceUs,
    this.piperVoiceUk = piperDefaultVoiceUk,
    this.downloadSource = AsrDownloadSource.huggingFace,
  });

  /// 当前口音对应的语言标签。
  String get languageTag => accent == TtsAccent.uk ? 'en-GB' : 'en-US';

  /// 当前口音下生效的 Kokoro 音色 id。
  String get activeKokoroVoice =>
      accent == TtsAccent.uk ? kokoroVoiceUk : kokoroVoiceUs;

  /// 当前口音下生效的 Piper 音色 id。
  String get activePiperVoice =>
      accent == TtsAccent.uk ? piperVoiceUk : piperVoiceUs;

  /// 派生引擎无关的发音配置。
  ///
  /// Kokoro 带音色（voiceName）+ 变体标签（modelTag，fp32/int8 分桶）；
  /// Piper 带音色（voiceName，即独立模型 id，缓存键据此分桶），无 modelTag；
  /// 平台引擎不带 voiceName/modelTag（用语言标签选系统音色）。语速本期固定 0.45。
  TtsSpeechConfig toSpeechConfig() => TtsSpeechConfig(
    languageTag: languageTag,
    voiceName: switch (engine) {
      TtsEngineKind.kokoro => activeKokoroVoice,
      TtsEngineKind.piper => activePiperVoice,
      TtsEngineKind.platform => null,
    },
    modelTag: engine == TtsEngineKind.kokoro ? kokoroVariant.name : null,
  );

  /// 同步从 [SharedPreferences] 派生当前状态，用于启动期 override 注入。
  factory TtsSettings.fromPrefsSync(SharedPreferences prefs) {
    return TtsSettings(
      engine: _engineFromName(prefs.getString(TtsSettingsKeys.engine)),
      accent: _accentFromName(prefs.getString(TtsSettingsKeys.accent)),
      kokoroVoiceUs: _voiceOrDefault(
        prefs.getString(TtsSettingsKeys.kokoroVoiceUs),
        TtsAccent.us,
      ),
      kokoroVoiceUk: _voiceOrDefault(
        prefs.getString(TtsSettingsKeys.kokoroVoiceUk),
        TtsAccent.uk,
      ),
      kokoroVariant: _variantFromName(
        prefs.getString(TtsSettingsKeys.kokoroVariant),
      ),
      piperVoiceUs: _piperVoiceOrDefault(
        prefs.getString(TtsSettingsKeys.piperVoiceUs),
        TtsAccent.us,
      ),
      piperVoiceUk: _piperVoiceOrDefault(
        prefs.getString(TtsSettingsKeys.piperVoiceUk),
        TtsAccent.uk,
      ),
      downloadSource: _downloadSourceFromName(
        prefs.getString(TtsSettingsKeys.downloadSource),
      ),
    );
  }

  /// 校验持久化的 Piper 音色 id 合法且口音匹配，否则回退该口音默认音色。
  static String _piperVoiceOrDefault(String? id, TtsAccent accent) {
    final v = id == null ? null : piperVoiceById(id);
    if (v != null && v.accent == accent) return v.id;
    return piperDefaultVoice(accent).id;
  }

  static KokoroModelVariant _variantFromName(String? name) {
    return KokoroModelVariant.values.firstWhere(
      (v) => v.name == name,
      orElse: () => KokoroModelVariant.fp32,
    );
  }

  /// 校验持久化的音色 id 合法且口音匹配，否则回退该口音默认音色。
  static String _voiceOrDefault(String? id, TtsAccent accent) {
    final v = id == null ? null : voiceById(id);
    if (v != null && v.accent == accent) return v.id;
    return defaultVoice(accent).id;
  }

  static TtsEngineKind _engineFromName(String? name) {
    if (name == TtsSettingsKeys.legacyTtsEngineValue) {
      return TtsEngineKind.kokoro;
    }
    return TtsEngineKind.values.firstWhere(
      (e) => e.name == name,
      orElse: () => TtsEngineKind.kokoro,
    );
  }

  static TtsAccent _accentFromName(String? name) {
    return TtsAccent.values.firstWhere(
      (a) => a.name == name,
      orElse: () => TtsAccent.us,
    );
  }

  static AsrDownloadSource _downloadSourceFromName(String? name) {
    return AsrDownloadSource.values.firstWhere(
      (source) => source.name == name,
      orElse: () => AsrDownloadSource.huggingFace,
    );
  }

  TtsSettings copyWith({
    TtsEngineKind? engine,
    TtsAccent? accent,
    String? kokoroVoiceUs,
    String? kokoroVoiceUk,
    KokoroModelVariant? kokoroVariant,
    String? piperVoiceUs,
    String? piperVoiceUk,
    AsrDownloadSource? downloadSource,
  }) {
    return TtsSettings(
      engine: engine ?? this.engine,
      accent: accent ?? this.accent,
      kokoroVoiceUs: kokoroVoiceUs ?? this.kokoroVoiceUs,
      kokoroVoiceUk: kokoroVoiceUk ?? this.kokoroVoiceUk,
      kokoroVariant: kokoroVariant ?? this.kokoroVariant,
      piperVoiceUs: piperVoiceUs ?? this.piperVoiceUs,
      piperVoiceUk: piperVoiceUk ?? this.piperVoiceUk,
      downloadSource: downloadSource ?? this.downloadSource,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TtsSettings &&
          runtimeType == other.runtimeType &&
          engine == other.engine &&
          accent == other.accent &&
          kokoroVoiceUs == other.kokoroVoiceUs &&
          kokoroVoiceUk == other.kokoroVoiceUk &&
          kokoroVariant == other.kokoroVariant &&
          piperVoiceUs == other.piperVoiceUs &&
          piperVoiceUk == other.piperVoiceUk &&
          downloadSource == other.downloadSource;

  @override
  int get hashCode => Object.hash(
    engine,
    accent,
    kokoroVoiceUs,
    kokoroVoiceUk,
    kokoroVariant,
    piperVoiceUs,
    piperVoiceUk,
    downloadSource,
  );
}

/// TTS 设置 Notifier。
///
/// 单向数据流：setter 仅写自己的 state + SP；TTS 协调器通过
/// `ref.listen(ttsSettingsProvider)` 监听变化重配引擎/口音。
class TtsSettingsNotifier extends Notifier<TtsSettings> {
  @override
  TtsSettings build() => ref.read(initialTtsSettingsProvider);

  /// 切换合成引擎，写 SP + 更新 state。
  Future<void> setEngine(TtsEngineKind engine) async {
    if (state.engine == engine) return;
    state = state.copyWith(engine: engine);
    await _persist(TtsSettingsKeys.engine, engine.name);
  }

  /// 切换口音，写 SP + 更新 state。
  Future<void> setAccent(TtsAccent accent) async {
    if (state.accent == accent) return;
    state = state.copyWith(accent: accent);
    await _persist(TtsSettingsKeys.accent, accent.name);
  }

  /// 设置指定口音的 Kokoro 音色，写 SP + 更新 state。
  ///
  /// [voiceId] 非法或与 [accent] 不匹配时忽略。
  Future<void> setKokoroVoice(TtsAccent accent, String voiceId) async {
    final v = voiceById(voiceId);
    if (v == null || v.accent != accent) return;
    if (accent == TtsAccent.uk) {
      if (state.kokoroVoiceUk == voiceId) return;
      state = state.copyWith(kokoroVoiceUk: voiceId);
      await _persist(TtsSettingsKeys.kokoroVoiceUk, voiceId);
    } else {
      if (state.kokoroVoiceUs == voiceId) return;
      state = state.copyWith(kokoroVoiceUs: voiceId);
      await _persist(TtsSettingsKeys.kokoroVoiceUs, voiceId);
    }
  }

  /// 切换 Kokoro 模型变体，写 SP + 更新 state。
  Future<void> setKokoroVariant(KokoroModelVariant variant) async {
    if (state.kokoroVariant == variant) return;
    state = state.copyWith(kokoroVariant: variant);
    await _persist(TtsSettingsKeys.kokoroVariant, variant.name);
  }

  /// 设置指定口音的 Piper 音色，写 SP + 更新 state。
  ///
  /// [voiceId] 非法或与 [accent] 不匹配时忽略。
  Future<void> setPiperVoice(TtsAccent accent, String voiceId) async {
    final v = piperVoiceById(voiceId);
    if (v == null || v.accent != accent) return;
    if (accent == TtsAccent.uk) {
      if (state.piperVoiceUk == voiceId) return;
      state = state.copyWith(piperVoiceUk: voiceId);
      await _persist(TtsSettingsKeys.piperVoiceUk, voiceId);
    } else {
      if (state.piperVoiceUs == voiceId) return;
      state = state.copyWith(piperVoiceUs: voiceId);
      await _persist(TtsSettingsKeys.piperVoiceUs, voiceId);
    }
  }

  /// 切换 TTS 模型下载来源（仅影响后续安装，已安装模型不重下）。
  Future<void> setDownloadSource(AsrDownloadSource source) async {
    if (state.downloadSource == source) return;
    state = state.copyWith(downloadSource: source);
    await _persist(TtsSettingsKeys.downloadSource, source.name);
  }

  Future<void> _persist(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (e) {
      AppLogger.log('TtsSettings', '写 SP 失败 ($key): $e');
    }
  }
}

/// TTS 设置 Provider 入口。
final ttsSettingsProvider = NotifierProvider<TtsSettingsNotifier, TtsSettings>(
  TtsSettingsNotifier.new,
);
