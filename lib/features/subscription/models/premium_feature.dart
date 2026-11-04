/// AI 能力标识，供现有调用点查询本机访问策略。
///
/// 名称沿用历史接口；供应商配置、余额与限流由实际请求处理。
library;

/// 本机访问策略使用的 AI 能力枚举。
enum PremiumFeature {
  /// AI 句子翻译。
  aiTranslation,

  /// AI 句子解析。
  aiAnalysis,

  /// AI 意群切分。
  aiSenseGroup,

  /// AI 单词深度解析。
  aiWordAnalysis,

  /// AI 转录字幕。
  aiTranscription,

  /// AI 对话助手。
  aiChat,

  /// AI 复述评估。
  aiRetellReview,
}
