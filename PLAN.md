# LoopBack 项目规划

> 最后更新：2026-11-11（三大去 EchoLoop 化项目全部合入 main，仓库开放票据清零；LoopBack 品牌更名与去品牌收尾完成——显示名/包名/通道/数据库文件全量更名，Firebase 与 iOS 网络权限触发整删，死资源清理；全部 EchoLoop 域名链接与商店上架内容已删除，项目不上架应用商店，仅 GitHub Releases 侧载分发）
> 当前焦点：语音识别、语音合成、词典与发音库三个去 EchoLoop 化项目已全部合入 `main`，规格与工单票据全部关闭；本地 main 领先 origin/main，推送与发布流程待定。实施明细见 [TASKS.md](./TASKS.md)；已如实记录的真机/Apple 剩余验证项继续跟踪。

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

### ✅ 语音识别去 EchoLoop 化（2026-11-08）

已完成并合入集成分支 `feature/20261106-asr-provider-decoupling`（明细见 [TASKS.md](./TASKS.md)）。三档 Whisper 改为固定公开源分发、不再依赖 EchoLoop 资源服务；字幕、跟读、复述可按用途选择本机、系统或在线，在线支持 OpenRouter 预设与 OpenAI 兼容转写，语音与文字 AI 配置及 Key 独立；字幕要求片段时间戳并如实标注词时间戳来源，长音频分块、进程内续试与原子提交；Key、能力验证与临时任务不进入备份。

剩余验证缺口：域名隔离后的真机抓包、Maestro 在线三用途流程与备份恢复往返、Apple 编译与集成测试、VAD 录音推理路径，均需 macOS 宿主或具备抓包条件的设备。原 Android 停录 native/VAD 崩溃仍独立跟踪，本次未修复。

### ✅ 语音合成去 EchoLoop 化（2026-11-10）

已完成并合入集成分支 `feature/20261110-tts-provider-decoupling`（明细见 [TASKS.md](./TASKS.md)）。Kokoro 与 Piper 改从固定公开源分发（csukuangfj 上游 HF 仓库逐文件 + 共享 `espeak-ng-data` 托管在 HF dataset），不再依赖 EchoLoop 资源 CDN，也不再依赖自建 GitHub 发布资产；界面还原真实模型名（Kokoro / Piper、Full precision (fp32) / Quantized (int8)）并展示来源与许可；音色按许可筛查收紧（Kokoro 升 v1.0 全 53 音色；Piper 只保留 public domain 的 6 个 + 1 个 CC-BY-SA 英音男声，lessac/alan/amy/ryan/hfc_female/cori-medium/alba 已移除并由启动迁移清理孤儿目录）。

剩余验证缺口：Apple 编译与集成测试需 macOS 宿主；集成分支并入 main 的发布流程待定；规格 issue #20 按 ASR #1 同约定保持开放。

### 🚧 Milestone 4：体验优化与生产就绪

持续推进中：

- 性能与稳定性优化。
- 多平台体验对齐（iOS / Android / macOS）。
- 播放、词典、PDF、字幕编辑等高频链路体验打磨。
- CI / Release / 更新链路稳定性完善。
- AI 对话助手：保留通用载体与 `SentenceChatButton`，请求改为供应商 Chat Completions SSE；不再依赖登录、会员或自有后端配额。当前契约以 [本地化规格](./docs/features/20261031-local-openai-localization/spec.md) 为准，旧 [chatbot 实施文档](./docs/chatbot-implementation-plan.md) 保留为历史。
- 语音识别设置页重排（2026-11-08，[issue #14](https://github.com/iron6909/loop-back/issues/14)）：按「识别方式 → 本机模型 → 在线服务」三层组织，三个用途各一行显示方式、模型与状态；本机模型改为资源库，在线服务独立成页并一次获取转写模型；管理字幕弹窗收拢为单一「模型转录」入口。明细见 [TASKS.md](./TASKS.md)。

### ⏸ Milestone 5：支付订阅（本分支已停用）

本地化改造停止 RevenueCat、Paddle、账号与 AI 配额门控，不再进行本分支的支付联调。AI 费用由用户配置的供应商处理。

历史设计保留：[权益单一来源](./docs/subscription-single-source-plan.md)、[订阅配置与发布说明](./docs/subscription-setup.md)。

## 近阶段工作重点

1. 在 Android 真机完成目录导入、本机转录、历史缺媒体与供应商设置验收。
2. 解决既有 Android 离线 ASR 闪退，保持独立复述转写不传 VAD 路径。
3. 在具备 macOS 宿主与抓包条件的设备上补齐语音识别去耦的剩余验收：Apple 编译与集成测试、在线三用途流程、域名隔离网络证据、VAD 录音路径。
4. 语音合成去 EchoLoop 化已实施完成（集成分支 `feature/20261110-tts-provider-decoupling`，真机验收通过）；剩余：Apple 编译待 macOS 宿主、分支合并与发布流程。
5. 完成启动埋点权限快照的手动验证。
6. 词典与发音库去 EchoLoop 化：方案已定稿（2026-11-10），规格与工单拆分待办；完成后共享 CDN 配置整体删除，正常流程不再引用任何 EchoLoop 域名（仅保留官网链接）。
7. 继续收敛录音识别模块复用边界与发布构建验证。

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
