# Echo Loop 自有后端 AI 外置化改造提案

## 问题与范围

目标：让 Echo Loop 不再依赖项目自有后端（`www.echo-loop.top` / `www.echo-loop.cn` 及其 API）提供 AI 能力，改为由用户自行配置一个**供应商提供的 OpenAI 兼容接口**；自有后端承载的其余能力按可行性替代、降级或停用。

### 已确认决策（2026-10-31，用户）

1. **客户端平台**：以 Android 为主；iOS / macOS 不作为本次验收目标。
2. **模型来源**：使用供应商提供的模型，不部署推理服务，不在设备或局域网运行本地 LLM。客户端保存 Base URL、模型名与 API Key。
3. **远程边界**：仅指本 App 自有后端接口。RSS 订阅、播客、音视频直链、网页词典、iTunes 搜索等第三方公网接口**不在改造范围**，保持原样。

### 取代的前置前提

上一版本把「整个应用禁止公网访问」列为候选边界并据此设计了资源导入、统计关闭、WebView 移除等方案。用户已明确排除该边界，本节取代该分支；早期提案仍保留在提交历史中，其对应内容不再作为设计依据。第三方公网接口既不在范围内，也不因本次改造被删除或降级。

### 已观察到的仓库事实

基于提交 `5574fe21a676184ada4f562f684e312b250998e4`，应用版本 `1.0.44`，Dart 约束 `^3.9.2`；本工作副本位于 `D:\Workspace\PersonalStudio\loop-back`。

1. 文本 AI（翻译、解析、单词/短语词典、意群、复述评估）与学习助手全部请求自有后端，使用自定义 NDJSON（`ops` 路径增量 + 完成帧），**不是** OpenAI Chat Completions 协议；缓存与 controller 依赖 `isFinal`。
2. 每次 AI 请求前有四层耦合：`isAuthenticatedProvider` 登录检查、`featureAccessProvider` 订阅/配额、Supabase Token Gate、`runtimeEndpointRouter` 区域路由。只改 Base URL 会被其中任一层拦截或改写。
3. 云端字幕走 `/api/v2/user-audio/*`（申请 R2 上传地址 → PUT → 提交任务 → 轮询 → 取回），不是 `/audio/transcriptions`；复述评估上传录音，由后端先转录再评估。
4. 已有 `LocalTranscriptionTaskManager` + `OfflineAsrEngine.transcribeSegments`，可本机完成转码、分段、SRT 与写库；ASR 模型目录只有英语 Whisper（`tiny.en` / `base.en` / `small.en`），而云端转录支持 `en` / `multi`。
5. Android 默认已使用离线 ASR；现有依赖（Dio 5.9.2、sherpa_onnx 1.13.4、flutter_secure_storage 10.0.0、FFmpeg）足以支撑直连供应商接口，无需新增 OpenAI SDK。

### 替换边界：自有后端接口清单

| 自有后端接口 | 承载功能 | 处置方向 |
| --- | --- | --- |
| `/api/v1/stream/{translate,analyze,lookup-word,lookup-phrase,sense-groups,evaluate-review}` | 翻译、解析、AI 词典、意群、复述评估 | 改为供应商 Chat Completions，客户端持有提示词与结果校验 |
| `/api/v1/stream/chat/sentence` | 学习助手多轮对话 | 同上，客户端组装系统提示词、上下文与引用 |
| `/api/v2/user-audio/*` + R2 PUT | 云端字幕转录 | 改用本机 Whisper 转录链路 |
| `/api/entitlements`、`/api/paddle/*` | 订阅权益、结账、客户门户 | 停用：本地 AI 不再由后端裁决额度，会员门控失去权威来源 |
| `/api/v1/client/config`、区域路由 | 启动配置、全球/中国切换 | 使用本地默认配置；单端点，无区域回退 |
| `/api/v1/me/preferences`、`/api/v1/me/onboarding` | 偏好与问卷云同步 | 仅本地保存（本地存储与备份已存在） |
| `/api/v2/collections*`、`/api/v1/featured-podcasts`、`/api/v1/netdisk/baidu/oauth/*` | 社区合集、精选播客、百度网盘导入 | **无本地等价物**，需决定隐藏入口或保留（保留则仍依赖自有后端） |
| `/version.json` | 应用更新检查 | 停用自更新检查，改用安装包手动更新 |
| `cdn.echo-loop.top` / `.cn` | ASR、TTS、词典、发音包下载 | 自有 CDN，需决定继续使用或增加本地导入 |

**明确不在范围**：iTunes 搜索、播客 RSS、音视频直链、网页词典、商店与帮助外链、PostHog / Firebase / 友盟上报。它们保持现状。

## 候选方案

### A. 客户端直连供应商 OpenAI 兼容接口（推荐）

**机制**：客户端保存 `baseUrl` + `model` + `apiKey`，用独立 Dio 调用 `POST {baseUrl}/chat/completions`；聊天消费 SSE 流，结构化功能请求完整 JSON 后本地校验并产出单个 `isFinal=true` 领域帧。转录改走已有本机 Whisper 链路。

**与现有代码的结合**：保留 Riverpod 状态、领域模型、缓存与 generation 守卫；替换点在 4 个 AI client / controller 的传输与鉴权边界，聊天已有 `ChatApi` 抽象可直接换实现。不新增供应商插件框架。

**收益**：不新增进程；用户自持凭据与成本；移除对自有后端的运行时依赖；Android 单平台验收面小。

**成本与失败模式**：客户端需自建提示词与最终结果校验，替代原后端逻辑；「OpenAI 兼容」不保证支持 `response_format`、流式或相同字段结构，弱模型可能返回错误 JSON、空内容或漏词意群。相比当前逐字段渐显，结构化结果等待更久。

**可逆性**：领域模型与存储边界不变，必要时可将编排迁入网关。

### B. 自建网关复刻原 NDJSON 协议（已排除）

原方案假设需要保留逐字段渐显或集中处理语音。在「供应商已提供 OpenAI 兼容接口」的前提下，网关只增加一个进程，却不能减少客户端工作：登录/配额/区域路由仍须在客户端解除，提示词与校验只是换了位置，且取消、部署与版本管理成本上升。**排除理由：收益消失、成本不变。**

### 已排除的捷径

- **只改 `API_BASE_URL`**：路径、NDJSON、Token Gate、区域路由、音频流程均不匹配。
- **把全部自有后端请求转 `/chat/completions`**：字幕、权益、配置、合集、网盘不是文本生成。
- **仅隐藏付费按钮**：Token Gate、配额检查与权益对账仍在运行。

## 推荐方案

采用 **A**。以下为待确认设计方向，不是已批准接口合同。

### 凭据与配置

- 设置入口提供 Base URL、模型名、API Key 与「连接验证」；验证执行一次最小推理请求，不依赖 `/models` 可用，模型名允许手填。
- Base URL 定义为 API 根路径（如 `https://api.example.com/v1`），拼接时保留用户子路径，拒绝非法 URI 与内嵌账号密码。
- API Key 存 `flutter_secure_storage`，不写入日志、SharedPreferences、埋点或备份；无 Key 时不发送伪造 Bearer。
- 独立 Dio：不带 Supabase token、平台/渠道头、权益拦截器，不经区域路由。

### 请求、结果与缓存

- 每功能使用短系统指令 + 目标语言 + 必要上下文 + 明确输出结构；学习原文、引用与转写一律作为数据，不作为指令。
- 结构保持现有领域模型：`grammar`/`vocabulary`/`listening`、`headword`+音标+释义、`originalExpression`+`keyPoints`、`medium`/`fine`、`transcript`/`keyPoints`/`corrections`/`summary`/`rating`/`suggestion`。
- 支持时请求 `response_format: {"type":"json_object"}`；无论是否支持，最终结果必须过结构、枚举、长度与语义校验（意群复用 `validateSenseGroupChunks`）。现有 `fromJson` 为展示半成品会容忍缺字段，**能反序列化不等于有效**，空对象/截断 JSON/漏词意群/缺评级一律不缓存。
- 聊天解析 SSE：按空行分事件、`data:` 前缀、`[DONE]` 结束、UTF-8 跨分片；只有确认正常完成才置成功，EOF 不冒充 final；用户停止保留已有文本。
- 缓存身份加入 `baseUrl|model|promptVersion|feature|targetLanguage|textHash`，Key 不入键；旧后端缓存与新配置隔离，不清库。
- 保存新配置时作废旧配置的在途请求与聊天上下文，沿用既有 generation / session 守卫。
- 错误映射：401 → Key/鉴权，404 → 地址或模型，429 → 供应商限流/额度，5xx → 重试一次后失败，超时单独提示。**不再引导登录或升级会员**。

### 解除自有后端耦合

- 在 `sentence_ai_provider`、`lookup_controller`、`chat_session_controller`、`retell_review_evaluation_provider` 移除 `isAuthenticatedProvider` / `featureAccessProvider` / `supabaseSessionProvider` 前置检查与 402 分支；保留取消、generation 与缓存逻辑。
- 停用订阅与 AI 额度 UI（其权威来源随 `/api/entitlements` 消失），避免展示无法兑现的权益。
- 远程配置改为本地默认值；`runtimeEndpointRouter` 不再参与 AI 请求。

### 语音与转录

- 云端字幕入口改走 `LocalTranscriptionTaskManager`：ffmpeg 转 16 kHz WAV → 分段转录 → SRT + 合成词级时间戳 → 写库。合成词级时间戳与云端真实对齐不等价，需在合同中明确精度预期。
- 复述评估：读取当前录音已有且同 attempt 的有效本地转写，否则独立引擎转写（**不传 VAD 路径**，避开已知 native 崩溃面，但不等于所有机型稳定），再把原文与转写交供应商 LLM 评估；转写失败不进入评估，不把 ASR 错误当作确定的语言错误。
- 不复用为云端上传准备的 AAC / 2 MB 上限合同；原录音不被覆盖，临时文件与引擎按既有生命周期清理。
- 多语言：本地模型仅英语，原云端支持 `multi`。保留该选项需另配多语言离线模型，否则须明确降级为英语。

## 选择状态

- **已确认**：Android 主平台；供应商 OpenAI 兼容接口 + 用户自带凭据；范围仅限自有后端接口。
- **推荐**：方案 A（方案 B 已排除）。
- **未决**：见下节四项，其中供应商与模型影响可行性判断。

## 可行性问题

**优先有界问题：选定供应商与模型能否稳定产出可用结构化结果。**

- 依赖决策：是否需为该供应商调整提示词、改用 JSON Schema 模式，或更换模型。
- 待补输入：供应商名称、模型 id、是否支持 `response_format` 与 SSE、速率/额度限制。
- 建议后续 `spike` 边界：用脱敏固定样例覆盖带上下文翻译、句子解析、单词、短语、意群、复述结构；记录有效 JSON 率、意群内容守恒、首字与总耗时。
- 决定标准：各必要功能均产出通过结构与语义校验的对象；仅部分通过则记为范围受限，不得宣布整体可行。
- 当前未执行该实验，也未认定任何供应商支持上述能力。

**其余未决（需用户决定，非实验问题）**

1. 自有后端内容功能（社区合集、精选播客、百度网盘导入）隐藏入口，还是保留（即仍依赖自有后端）？
2. ASR / TTS / 词典模型继续从自有 CDN 下载，还是增加本地文件导入？
3. 云端转录的 `multi` 多语言是否保留（本地模型仅英语）？
4. 订阅与 AI 额度 UI 直接移除，还是保留只读展示？

**普通实施验证**：Key 不入日志与备份、配置切换后旧回调作废、SSE 跨分片与 `[DONE]`、错误 JSON 不落缓存、取消与断流、静音与长音频转录、复述原录音保留。可沿用 `test/services/sentence_ai_api_client_test.dart`、`test/providers/sentence_ai_provider_test.dart`、`test/providers/retell_review_evaluation_provider_test.dart` 及本地转录相关测试；本轮未执行。

## 来源与保全

- 用户输入：本会话两轮。第一轮确定「本地 LLM + OpenAI 兼容 + 覆盖远程接口」；第二轮修正为 Android 主平台、供应商模型（不部署）、边界仅限自有后端接口。两点均已在「已确认决策」落文，未删除早期候选，仅记录取代关系。
- 代码基线：`5574fe21a676184ada4f562f684e312b250998e4`（应用 `1.0.44`）。工作副本由该提交的本地克隆建立，`origin` 改名为 `source-local`，未推送。
- 规则与现状：`AGENTS.md`、`CLAUDE.md`、`PLAN.md`、`TASKS.md`、`pubspec.yaml`、`pubspec.lock`。未发现 `GLOSSARY.md`、`docs/learnings/` 或既有同范围 feature 目录。
- 代码来源：`lib/services/sentence_ai_api_client.dart`、`lib/features/chatbot/{services/chat_api_client.dart,providers/chat_session_controller.dart}`、`lib/providers/sentence_ai_provider.dart`、`lib/providers/retell_review_evaluation_provider.dart`、`lib/services/dictionary/ai_dictionary_source.dart`、`lib/providers/dictionary/lookup_controller.dart`、`lib/services/backend_dio.dart`、`lib/features/subscription/providers/feature_access_provider.dart`、`lib/services/transcription_api_client.dart`、`lib/providers/local_transcription_task_provider.dart`、`lib/services/asr/{sherpa_onnx_engine.dart,asr_model_catalog.dart}`、`lib/models/{sentence_ai_result.dart,dictionary/dictionary_entry.dart,sense_group_result.dart,retell_review_evaluation.dart}`。
- 证据限制：仅静态代码与仓库文档；未读取真实密钥，未调用任何供应商或自有后端接口，未运行应用、测试或实验。供应商兼容性、模型质量与耗时均未验证。
- 覆盖检查：自有后端接口按清单逐项处置，第三方公网接口显式排除；未决事项未被当作已批准删除。无需额外内部附件。
