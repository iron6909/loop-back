/// 在线语音的能力验证结论与上传告知记录。
///
/// 两者都只放普通偏好，不含 Key 材料：能力记录用「服务类型 + 根地址 + 模型 +
/// 凭据版本」作为非秘密身份，任何一项变化都会让旧结论不再匹配；上传告知按服务
/// 根地址记录，换地址必须重新告知。这些记录排除在备份外，恢复时显式清理。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'speech_config.dart';

/// 一次能力验证的结论。
class SpeechCapability {
  const SpeechCapability({
    required this.identity,
    required this.text,
    required this.segments,
    required this.wordTimestamps,
    required this.validatedAt,
    this.reportedCost,
  });

  /// 非秘密配置身份；只有与当前配置完全一致时结论才可用。
  final String identity;

  /// 能返回有效非空文本。
  final bool text;

  /// 能返回合法的片段时间戳，也就是字幕可用。
  final bool segments;

  /// 请求过词时间戳参数并全部通过校验；未请求时视为未验证。
  final bool wordTimestamps;

  final DateTime validatedAt;

  /// 供应商报告的本次费用；没有给出时为 null，不按免费处理。
  final double? reportedCost;

  /// 非秘密配置身份。
  ///
  /// 用随机凭据版本而不是 Key 的明文或摘要，Key 变化无须把材料写进普通存储
  /// 也能让旧验证失效。
  static String identityFor({
    required SpeechProviderKind kind,
    required String baseUrl,
    required String modelId,
    required String? credentialVersion,
  }) => '${kind.name}|${_normalizeRoot(baseUrl)}|${modelId.trim()}|'
      '${credentialVersion ?? ''}';

  /// 只用于日志与调试：不含凭据。
  @override
  String toString() =>
      'SpeechCapability(text=$text, segments=$segments, '
      'words=$wordTimestamps)';

  Map<String, Object?> toJson() => {
    'identity': identity,
    'text': text,
    'segments': segments,
    'wordTimestamps': wordTimestamps,
    'validatedAt': validatedAt.toIso8601String(),
    if (reportedCost case final cost?) 'reportedCost': cost,
  };

  /// 损坏或不完整的记录不产生结论。
  static SpeechCapability? fromJson(Object? value) {
    if (value case {
      'identity': String identity,
      'text': bool text,
      'segments': bool segments,
      'wordTimestamps': bool wordTimestamps,
      'validatedAt': String validatedAt,
    }) {
      final at = DateTime.tryParse(validatedAt);
      if (at == null || identity.isEmpty) return null;
      return SpeechCapability(
        identity: identity,
        text: text,
        segments: segments,
        wordTimestamps: wordTimestamps,
        validatedAt: at,
        reportedCost: switch (value['reportedCost']) {
          final num cost when cost.isFinite && cost >= 0 => cost.toDouble(),
          _ => null,
        },
      );
    }
    return null;
  }
}

/// 能力结论与上传告知的本地存储入口。
class SpeechCapabilityStore {
  SpeechCapabilityStore({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;

  /// 供备份黑名单使用：本机验证状态与告知都不跨设备恢复。
  static const preferencePrefix = 'speech_capability_';

  /// 已确认的服务地址（含告知）的存储槽。
  static const uploadNoticePreferenceKey = '${preferencePrefix}upload_notice_v1';

  /// 能力结论的存储槽。
  static const recordsPreferenceKey = '${preferencePrefix}records_v1';

  /// 读取全部结论，按身份索引；损坏的条目直接忽略。
  Future<Map<String, SpeechCapability>> readAll() async {
    final preferences = await _preferences();
    final raw = preferences.getString(recordsPreferenceKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, SpeechCapability>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        if (key is! String) continue;
        final capability = SpeechCapability.fromJson(entry.value);
        if (capability != null && capability.identity == key) {
          result[key] = capability;
        }
      }
      return result;
    } on FormatException {
      return {};
    }
  }

  /// 按非秘密配置身份取结论；配置变化后自然读不到旧结论。
  Future<SpeechCapability?> read(String identity) async =>
      (await readAll())[identity];

  /// 保存一次结论；写入失败直接抛给调用方，不伪造已验证状态。
  Future<void> save(SpeechCapability capability) async {
    final preferences = await _preferences();
    final records = await readAll();
    records[capability.identity] = capability;
    if (!await preferences.setString(
      recordsPreferenceKey,
      jsonEncode({
        for (final entry in records.entries) entry.key: entry.value.toJson(),
      }),
    )) {
      throw StateError('无法保存在线语音能力验证结果');
    }
  }

  /// 服务根地址是否已经完成上传告知。
  Future<bool> hasUploadNotice(String baseUrl) async {
    final preferences = await _preferences();
    return preferences.getString(uploadNoticePreferenceKey) ==
        _normalizeRoot(baseUrl);
  }

  /// 记录用户已确认向该服务上传测试样本并可能被收费。
  Future<void> rememberUploadNotice(String baseUrl) async {
    final preferences = await _preferences();
    if (!await preferences.setString(
      uploadNoticePreferenceKey,
      _normalizeRoot(baseUrl),
    )) {
      throw StateError('无法保存在线语音上传告知');
    }
  }

  /// 清除本机结论与告知；备份恢复成功后必须调用，避免沿用旧验证。
  Future<void> clear() async {
    final preferences = await _preferences();
    await preferences.remove(recordsPreferenceKey);
    await preferences.remove(uploadNoticePreferenceKey);
  }
}

/// 根地址末尾斜杠不产生两个不同的服务身份。
String _normalizeRoot(String baseUrl) =>
    baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
