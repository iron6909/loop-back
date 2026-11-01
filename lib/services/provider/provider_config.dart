/// 用户供应商配置；凭据只由安全存储持有，不属于此模型。
library;

/// 预设只填默认值，用户仍可编辑地址和模型。
enum ProviderKind {
  deepseek,
  openrouter,
  custom;

  String? get presetBaseUrl => switch (this) {
    deepseek => 'https://api.deepseek.com',
    openrouter => 'https://openrouter.ai/api/v1',
    custom => null,
  };

  String? get presetModel => switch (this) {
    deepseek => 'deepseek-flash',
    openrouter => 'mistralai/mistral-nemo',
    custom => null,
  };
}

/// Base URL 直接追加 /chat/completions；不自动补 /v1。
class ProviderConfig {
  const ProviderConfig({
    required this.kind,
    required this.baseUrl,
    required this.model,
    this.promptVersion = 'v1',
  });

  final ProviderKind kind;
  final String baseUrl;
  final String model;
  final String promptVersion;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'baseUrl': baseUrl,
    'model': model,
    'promptVersion': promptVersion,
  };

  /// 损坏的本地记录不产生可用配置。
  static ProviderConfig? fromJson(Object? value) {
    if (value case {
      'kind': String kind,
      'baseUrl': String url,
      'model': String model,
      'promptVersion': String version,
    }) {
      final selected = ProviderKind.values.where((item) => item.name == kind);
      if (selected.isEmpty || baseUrlError(url) != null) return null;
      if (model.trim().isEmpty || version.trim().isEmpty) return null;
      return ProviderConfig(
        kind: selected.first,
        baseUrl: url,
        model: model,
        promptVersion: version,
      );
    }
    return null;
  }
}

/// 尚未配置供应商；AI 入口据此提示去配置，不得发出推理请求。
///
/// 定义在服务层，使客户端无需依赖 providers 层即可报出该错误。
class ProviderNotConfiguredException implements Exception {
  const ProviderNotConfiguredException();

  @override
  String toString() => 'ProviderNotConfiguredException';
}

/// 拒绝带凭据、查询串及片段的地址，避免凭据经 URL 或日志泄漏。
String? baseUrlError(String value) {
  final uri = Uri.tryParse(value);
  if (value.trim().isEmpty ||
      value != value.trim() ||
      RegExp(r'\s').hasMatch(value) ||
      uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      !uri.hasAuthority ||
      uri.host.isEmpty) {
    return '请填写完整的 HTTP 或 HTTPS 地址';
  }
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
    return '地址不能包含账号、密码、查询参数或片段';
  }
  return null;
}
