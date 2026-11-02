/// 通用 Chatbot 组件的编译期开关。
///
/// 编译期开关保留硬停能力；运行期显隐由功能配置
/// （`RemoteFeature.aiChatAssistant`）控制。
library;

/// 是否对用户暴露 chatbot 入口（句子讲解页 / 学习任务页 AppBar AI 按钮等）。
///
/// 当前 **true**：聊天走用户自配的供应商接口。如需全平台紧急下线改回 false。
const bool kChatbotEnabled = true;
