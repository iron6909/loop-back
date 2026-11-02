# Echo Loop 项目规划

> 最后更新：2026-11-02（供应商直连与自有后端本地化）
> 当前焦点：Android 本地化改造收尾；代码已交付，最终真机验收待设备。规格与实施计划见 [spec.md](./docs/features/20261031-local-openai-localization/spec.md)、[plan.md](./docs/features/20261031-local-openai-localization/plan.md)。

## 产品目标

Echo Loop 是一个围绕“音频输入 + 句子级学习 + 间隔复习 + AI 辅助”的英语学习应用。核心目标：

- 让用户围绕真实音频材料完成首次学习与后续复习。
- 保持主学习闭环免费，AI 由用户配置的供应商提供，不阻断本地学习流程。
- 优先保证播放器、学习流转、状态一致性和多平台稳定性。

## 当前状态

已稳定上线的能力：

- 音频导入、字幕管理、字幕编辑、自由播放器。
- 首次学习主流程：全文盲听、逐句精听、难句跟读、段落复述。
- 收藏体系：句子、单词、意群、收藏复习。
- 词典体系：本地词典、AI 词典、网页词典、多源切换、非 modal 面板。
- AI 能力：翻译、句子解析、词典、意群、复述评估与学习助手直连用户配置的供应商；字幕与复述录音转写使用本机英语模型。
- PDF 导出：学习材料导出为可打印 PDF。
- 本地内容：Android 目录导入为合集，精选播客随包读取；账号、会员结账、云端字幕、社区同步、网盘导入与自更新已停用，历史学习数据保留。

当前主要风险：

- Android 离线 ASR 在部分机型结束录音后触发 native 崩溃，仍未定位到最终 root cause。
- 供应商直连与本地化改造仍待 Android 真机验证：目录入库、缺字幕转录、历史缺媒体禁用及 AI 服务页各状态；自动化检查不能替代这些设备证据。
- 冷启动已将重型初始化移出首帧路径，并以 Riverpod `AsyncValue` 统一管理本地数据初始化状态；本地数据失败时不再阻断导航壳，首页提供重试与日志入口。仍需在受影响 iOS 真机上用启动日志核验迁移失败原因和首帧实际耗时。

## 当前里程碑

### ✅ Milestone 1：基础播放器

已完成。覆盖音频导入、全文/单句/收藏三种播放模式、字幕同步、收藏与基础播放控制。

### 🚧 Milestone 2：学习流程引擎

主体已完成，剩余收尾集中在录音识别稳定性：

- 已完成：首次学习流程、阶段状态流转、断点续学、难度驱动的训练编排。
- 已完成：难句补练、收藏复习、盲听与复述共享骨架。
- 未完成：Android 离线 ASR 闪退根因定位与修复；段落复述继续复用统一录音识别模块。

### ✅ Milestone 3：收藏与标注体系

已完成。覆盖 Favorites、句子/单词/意群收藏、收藏复习、词典联动与标注内容展示。

### 🚧 Milestone 4：体验优化与生产就绪

持续推进中：

- 性能与稳定性优化。
- 多平台体验对齐（iOS / Android / macOS）。
- 播放、词典、PDF、字幕编辑等高频链路体验打磨。
- CI / Release / 更新链路稳定性完善。
- AI 对话助手：保留通用载体与 `SentenceChatButton`，请求改为供应商 Chat Completions SSE；不再依赖登录、会员或自有后端配额。当前契约以 [本地化规格](./docs/features/20261031-local-openai-localization/spec.md) 为准，旧 [chatbot 实施文档](./docs/chatbot-implementation-plan.md) 保留为历史。

### ⏸ Milestone 5：支付订阅（本分支已停用）

本地化改造停止 RevenueCat、Paddle、账号与 AI 配额门控，不再进行本分支的支付联调。AI 费用由用户配置的供应商处理。

历史设计保留：[权益单一来源](./docs/subscription-single-source-plan.md)、[订阅配置与发布说明](./docs/subscription-setup.md)。

## 近阶段工作重点

1. 在 Android 真机完成目录导入、本机转录、历史缺媒体与供应商设置验收。
2. 解决既有 Android 离线 ASR 闪退，保持独立复述转写不传 VAD 路径。
3. 完成启动埋点权限快照的手动验证。
4. 继续收敛录音识别模块复用边界与发布构建验证。

## 架构约束（精简版）

- 单向数据流：UI 触发动作，provider / controller 改状态，UI 被动渲染。
- 页面负责组装，组件负责展示，复杂流程下沉到可测试的纯 Dart 编排层。
- 副作用通过 service / repository 注入，不把网络、文件、平台调用散落到 UI。
- 异步流程必须带 session / token / generation guard，防止旧回调污染新状态。
- 学习统计新写入链路用于全部学习任务（随心听、收藏复习、逐句精听、难句跟读、全文盲听、段落复述和难句补练）：
  页面 → Provider → StudySessionTimer → StudyTimeService FIFO 队列 → StudyStatisticsDao 单事务；
  计时器按页面生命周期创建/销毁，播放完成事件写入输入统计，录音完成事件写入输出统计，用户无活动超过
  2 分钟才暂停总学习时长。学习任务不再保留独立的 StudyEventRecorder、StudyStatisticsRecorder 或旧式 add* 增量写入链路。
- 新链路使用的日统计、阶段统计和词形事务能力保持集中实现，避免新增调用方绕过
  统一写入口。
- 新增能力优先补状态流转测试与关键回归测试。

## 关键 ADR 索引

- 媒体引擎与前台引擎分离：避免锁屏媒体会话与前台试听互相污染。
- 统一 TTS 架构：合成 → 文件 → 缓存 → 播放，支持平台 TTS 与 Kokoro 本地 TTS。
- 离线转录与本地模型：复用统一音频处理与模型下载能力。
- 平台 + 渠道统一识别：既有发布/分析识别保留；支付与自有后端配额策略在本分支停用。
- 通用记忆调度基础设施：以独立调度快照与只追加复习事件建模；上层依赖应用自有接口，FSRS 仅限 adapter 内部，按逐项固定 Profile 保障可迁移与可审计性（见 [memory-scheduler-infrastructure-plan.md](./docs/memory-scheduler-infrastructure-plan.md)）。

详细历史与旧版长文档已归档：

- [2026-07-12 全量规划快照](./docs/plan-archive/plan-2026-07-12-full.md)

日常执行请结合：

- [TASKS.md](./TASKS.md)
- [AGENTS.md](./AGENTS.md)
