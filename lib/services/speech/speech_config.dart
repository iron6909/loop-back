/// 在线语音服务的普通配置；凭据只由安全存储持有，不属于此模型。
library;

import '../../models/recognition_selection.dart';
import '../provider/provider_config.dart' show baseUrlError;

/// 在线语音服务预设。
///
/// 预设只提供根地址；在线模型始终由用户按用途填写，不从预设推断。
enum SpeechProviderKind {
  openrouter,
  custom;

  /// 直接追加 `/audio/transcriptions` 的根地址；自定义服务由用户填写。
  String? get presetBaseUrl => switch (this) {
    openrouter => 'https://openrouter.ai/api/v1',
    custom => null,
  };
}

/// 一份语音服务配置：全用途共用服务类型与根地址，各自保存在线模型 ID。
///
/// 与文字 AI 的 `ProviderConfig` 分槽保存，用户可以填入相同的 Key，但不建立
/// 自动共享关系。识别方式（本机 / 系统 / 在线）仍由按用途识别设置管理，这里只
/// 记录在线方式要用的服务与模型。
class SpeechConfig {
  const SpeechConfig({
    required this.kind,
    required this.baseUrl,
    this.onlineModels = const {},
  });

  final SpeechProviderKind kind;

  /// 根地址；保留合法子路径，不自动补 `/v1`。
  final String baseUrl;

  /// 三个用途各自的在线模型 ID；缺项表示该用途尚未选择模型。
  final Map<RecognitionPurpose, String> onlineModels;

  /// 指定用途的在线模型 ID；未选择时为空字符串。
  String onlineModelFor(RecognitionPurpose purpose) =>
      onlineModels[purpose] ?? '';

  /// 只替换某用途的在线模型，保留服务地址与其它用途的选择。
  SpeechConfig withOnlineModel(RecognitionPurpose purpose, String modelId) =>
      SpeechConfig(
        kind: kind,
        baseUrl: baseUrl,
        onlineModels: {...onlineModels, purpose: modelId.trim()},
      );

  /// 在线转写请求地址：根地址直接追加 `/audio/transcriptions`。
  String get transcriptionUrl => '$baseRoot/audio/transcriptions';

  /// 去掉末尾斜杠的根地址；用于拼接同服务的其它接口，避免出现双斜杠。
  String get baseRoot => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'baseUrl': baseUrl,
    'models': {
      for (final entry in onlineModels.entries)
        if (entry.value.trim().isNotEmpty) entry.key.name: entry.value,
    },
  };

  /// 损坏或不可用的本地记录不产生配置；未知用途的模型条目忽略。
  static SpeechConfig? fromJson(Object? value) {
    if (value case {'kind': String kind, 'baseUrl': String url}) {
      final selected = SpeechProviderKind.values.where(
        (item) => item.name == kind,
      );
      if (selected.isEmpty || baseUrlError(url) != null) return null;
      final models = <RecognitionPurpose, String>{};
      if (value case {'models': final Map<Object?, Object?> raw}) {
        for (final purpose in RecognitionPurpose.values) {
          final modelId = raw[purpose.name];
          if (modelId is String && modelId.trim().isNotEmpty) {
            models[purpose] = modelId;
          }
        }
      }
      return SpeechConfig(
        kind: selected.first,
        baseUrl: url,
        onlineModels: models,
      );
    }
    return null;
  }

  @override
  bool operator ==(Object other) {
    if (other is! SpeechConfig ||
        other.kind != kind ||
        other.baseUrl != baseUrl ||
        other.onlineModels.length != onlineModels.length) {
      return false;
    }
    for (final entry in onlineModels.entries) {
      if (other.onlineModels[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    kind,
    baseUrl,
    Object.hashAllUnordered(
      onlineModels.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );

  /// 只用于日志与调试：不含凭据，凭据不在本模型中。
  @override
  String toString() => 'SpeechConfig(${kind.name}, $baseUrl)';
}
