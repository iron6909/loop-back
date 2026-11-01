/// 结构化输出的模式选择与回落判定
///
/// spec「输出模式选择」的可执行版本：首选严格 `json_schema`，只在供应商**明确**
/// 表示不支持该输出模式时回落一次 `json_object`。其余一切失败都判失败——
/// 回落不是「再试一次让它变绿」，它只解决「这个端点不认 response_format」。
library;

/// 结构化输出的模式。
enum OutputMode {
  /// 严格 JSON Schema（`strict` / `required` / `additionalProperties: false`）。
  jsonSchema,

  /// 仅约定「返回 JSON 对象」的兼容模式。
  jsonObject,
}

/// 一次失败的分类，决定是否允许回落。
enum OutputFailureKind {
  /// 供应商明确拒绝当前输出模式（HTTP 400/422 且错误体点名 `response_format`）。
  unsupportedOutputMode,

  /// 模型因输出预算耗尽被截断（`finish_reason=length`）。
  truncated,

  /// 正文为空。
  emptyBody,

  /// 正文不是 JSON 对象。
  notJsonObject,

  /// 内容校验失败：字段类型错误、枚举缺值、必填缺失、意群不守恒。
  invalidResult,

  /// 传输层失败：网络、超时、鉴权、限流、服务端错误。
  transport,
}

/// 依据失败分类决定下一个输出模式；返回 null 表示终止、不再重试。
///
/// 只有「当前是严格 Schema」且「供应商明确不支持」才回落一次；[OutputMode.jsonObject]
/// 已是最后一档，再失败就是失败。
OutputMode? fallbackOutputMode({
  required OutputMode current,
  required OutputFailureKind failure,
}) {
  if (current != OutputMode.jsonSchema) return null;
  if (failure != OutputFailureKind.unsupportedOutputMode) return null;
  return OutputMode.jsonObject;
}

/// 判断一次 HTTP 错误是否**明确**表示不支持当前输出模式。
///
/// 判据同时满足才算：
/// 1. 状态码为 400 或 422（其余状态码由重试或错误映射处理）；
/// 2. 错误体同时出现输出模式关键字（`response_format` / `json_schema`）与
///    拒绝用语（unsupported / not supported / invalid / unknown）。
///
/// 只凭关键字之一就回落会把「模型不存在」这类 400 误判成模式不支持。
bool indicatesUnsupportedOutputMode({
  required int? statusCode,
  required String? errorBody,
}) {
  if (statusCode != 400 && statusCode != 422) return false;
  if (errorBody == null || errorBody.isEmpty) return false;

  final body = errorBody.toLowerCase();
  final mentionsMode =
      body.contains('response_format') || body.contains('json_schema');
  if (!mentionsMode) return false;

  return body.contains('unsupported') ||
      body.contains('not supported') ||
      body.contains('invalid') ||
      body.contains('unknown');
}
