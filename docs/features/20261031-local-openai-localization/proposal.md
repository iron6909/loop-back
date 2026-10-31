# Echo Loop 自有后端 AI 外置化改造提案

## 问题与范围

目标：让 Echo Loop 不再依赖项目自有后端（`www.echo-loop.top` / `www.echo-loop.cn` 及其 API）提供 AI 能力，改为由用户自行配置一个**供应商提供的 OpenAI 兼容接口**；自有后端承载的其余能力按可行性替代、降级或停用。

### 已确认决策（2026-10-31，用户）

1. **客户端平台**：以 Android 为主；iOS / macOS 不作为本次验收目标。
2. **模型来源**：使用供应商提供的模型，不部署推理服务，不在设备或局域网运行本地 LLM。客户端保存 Base URL、模型名与 API Key。
3. **远程边界**：仅指本 App 自有后端接口。RSS 订阅、播客、音视频直链、网页词典、iTunes 搜索等第三方公网接口**不在改造范围**，保持原样。
4. **社区合集**：接受功能变化——移除发现页，改为用户直接选目录导入本地合集，不做清单文件。
5. **精选播客**：内置本地播客清单，同时保留用户自粘 RSS / Apple 链接的入口。
6. **模型资源**：保留现有 CDN 下载，不增加本地文件导入。
7. **转录语言**：收敛为英语，不引入多语言 Whisper。
8. **额度 UI**：保留只读展示；若配置的是 OpenCode Go，展示该套餐额度。

### 供应商接口依据（官方文档核实，2026-10-31）

| 项目 | OpenRouter | DeepSeek |
| --- | --- | --- |
| Base URL | `https://openrouter.ai/api/v1` | `https://api.deepseek.com` |
| 对话端点 | `POST /api/v1/chat/completions` | `POST /chat/completions` |
| 协议自述 | 请求/响应 schema “very similar to OpenAI's APIs”，跨供应商归一化 | 兼容 OpenAI / Anthropic 格式 |
| 结构化输出 | `response_format: {type:'json_schema', json_schema:{strict:true,...}}`；仅部分模型/端点支持，可用 `require_parameters:true` 限定路由 | `response_format: {type:'json_object'}`（JSON Output） |
| 流式 | SSE：`data:` 行 + `[DONE]` | `stream: true` |
| 模型名 | 由目录决定，客户端手填 | `deepseek-flash`、`deepseek-v4-pro` |

由此确定两条设计约束：

- 两家 Base URL 形态不同（一个有 `/v1`，一个没有）。客户端必须把 Base URL 定义为**直接追加 `/chat/completions` 的根路径**，不做 `/v1` 自动补全。
- OpenRouter 流末尾额外发送带 `usage` 的分片，其 `choices[0].delta` 内容为空但重复 `finish_reason`。解析时不得把它当新文本，也不得在 `delta` 缺失时崩溃。

#### OpenCode Go（第三个候选供应商）

- 计划：Go `$10/月`、Go Plus `$40/月`、Go Teams `$20/人/月`；额度按每月美元上限计，每个模型再分三档：5 小时 = 20%、每周 = 50%、每月 = 100%。
- Base URL 与套餐绑定：Go 走 `https://opencode.ai/inference/go/openai/v1/chat/completions`（与 pay-as-you-go 不同）。按本提案的「根路径 + `/chat/completions`」规则，用户填 `https://opencode.ai/inference/go/openai/v1`。
- 额度查询是独立官方接口：`GET https://opencode.ai/zen/go/v1/usage`，Bearer 使用同一把 API Key，返回 `usage.rolling/weekly/monthly` 的 `status`、`percent`、`resetsAt`；403 表示 Key 有效但无 Go 订阅，401 为鉴权失败。

#### 关于「现成 AI 集成项目」（LiteLLM 等）

- LiteLLM 是 **Python SDK + 自托管网关**（docker 部署），把 100+ 供应商归一成 OpenAI 格式，并提供虚拟 Key、预算与成本记录；它不是 Dart 库，**无法嵌入 Flutter 客户端**。
- 采用 LiteLLM 等于运行一个代理进程，即本提案已排除的方案 B：多一个进程，却不减少客户端工作（门控、提示词、校验仍在客户端）。
- 兼容收益不依赖它：客户端只讲标准 Chat Completions，将来若需要路由/回退/预算，可以**不改客户端**把 Base URL 指向 LiteLLM 或任何网关。这是设计留出的兼容面，不是运行时依赖。
- Dart 侧 `openai_dart` 之类包也不解决供应商差异，只是把几行 Dio 包一层，故不引入。
- 需处理的差异已被枚举且很少：Base URL 形态、`response_format` 模式（`json_schema` vs `json_object`）、OpenRouter 末尾 `usage` 分片。一个薄适配层即可覆盖。

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
| `/api/entitlements`、`/api/paddle/*` | 订阅权益、结账、客户门户 | 停止门控与结账；额度 UI 改为只读，改由供应商额度接口提供（见下节） |
| `/api/v1/client/config`、区域路由 | 启动配置、全球/中国切换 | 使用本地默认配置；单端点，无区域回退 |
| `/api/v1/me/preferences`、`/api/v1/me/onboarding` | 偏好与问卷云同步 | 仅本地保存（本地存储与备份已存在） |
| `/api/v2/collections*` | 社区合集发现、加入、文件与字幕 | 改为本地目录导入；发现页移除（见下节） |
| `/api/v1/featured-podcasts` | 精选播客目录 | 改为内置本地清单，保留自粘链接入口（见下节） |
| `/api/v1/netdisk/baidu/oauth/*` | 百度网盘导入 | 改为本地文件导入（已有批量导入能力） |
| `/version.json` | 应用更新检查 | 停用自更新检查，改用安装包手动更新 |
| `cdn.echo-loop.top` / `.cn` | ASR、TTS、词典、发音包下载 | 保留：静态资源托管而非业务接口（见下节） |

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
- 移除订阅门控与结账；额度 UI 改为只读展示（见下节），不再展示无法兑现的会员权益。

### 只读额度展示

- 门控全部移除：不再因为「未登录 / 非会员 / 额度用尽」阻断 AI 调用；额度只用于展示。
- 仅当配置的 Base URL 属于 OpenCode Go（`opencode.ai/inference/go/...`）时，才请求 `GET https://opencode.ai/zen/go/v1/usage`，Bearer 复用同一把已存的 API Key。
- 展示三档窗口（5 小时 / 每周 / 每月）的百分比与重置时间；主标题取剩余最少的一档，与 OpenCode 自身展示一致。
- 状态映射：200 → 正常展示；403 → 「当前 Key 无 Go 订阅」；401 → 「Key 无效」；404 或其他 → 不展示该卡片，只记日志（视为接口漂移，不打扰用户）。
- `percent = 0` 时上游 `resetsAt` 是占位值，此时不显示倒计时。
- 额度请求失败不得影响 AI 请求，也不得自动重试轰炸；进入设置页或手动刷新时获取，结果短期缓存。
- 其他供应商（OpenRouter / DeepSeek）没有统一的额度接口，不展示余额，避免编造。
- 远程配置改为本地默认值；`runtimeEndpointRouter` 不再参与 AI 请求。

### 语音与转录

- 云端字幕入口改走 `LocalTranscriptionTaskManager`：ffmpeg 转 16 kHz WAV → 分段转录 → SRT + 合成词级时间戳 → 写库。合成词级时间戳与云端真实对齐不等价，需在合同中明确精度预期。
- 复述评估：读取当前录音已有且同 attempt 的有效本地转写，否则独立引擎转写（**不传 VAD 路径**，避开已知 native 崩溃面，但不等于所有机型稳定），再把原文与转写交供应商 LLM 评估；转写失败不进入评估，不把 ASR 错误当作确定的语言错误。
- 不复用为云端上传准备的 AAC / 2 MB 上限合同；原录音不被覆盖，临时文件与引擎按既有生命周期清理。
- 多语言：已确认**收敛为英语**。界面实际只提供 `en` 与 `auto`（自动检测）两项；`audio_items.transcript_language` 的注释写作 `'en' / 'multi'` 属历史遗留，`'multi'` 仅出现在测试中。本地 Whisper 只有英语模型，改造后移除 `auto` 选项，已有 `transcriptLanguage='auto'` 的历史字幕仅作展示，不重新生成。

### 社区合集：现状与本地替代

**现状（代码事实）**

- 三个匿名只读接口：`GET /api/v2/collections`（20 条游标分页）、`GET /api/v2/collections/{id}`（合集 + 文件分页）、`GET /api/v2/collections/{id}/files/{fileId}`（单文件元数据 + 字幕 `sentences` / `words`）。不需要登录。
- 目录分页缓存在应用缓存目录 `community_collection_catalog/`，正文与 `meta` 分离，`meta` 保存 sha256 与 `lastFetchedAt`。
- 「加入」把远端 `remoteId` 写入本地 `collections` 行（`source='community'`）；`CommunitySyncService` 之后按**每合集 2 小时**基线同步：拉全部分页 → 按 `remoteAudioId` upsert `audio_items` → 维护 `collection_audio_items.sortOrder` → 远端已消失的文件交给 `CommunityFileLifecycleService.markUnavailable`（有本地进度/收藏则标记不可用，否则删除）。
- 媒体下载使用 `mediaUrl` / `mediaUrlChina`（按地区二选一），交给后台下载器落盘。
- 因此该功能是「远端目录 + 远端媒体 + 本地学习数据」三层耦合，不是单纯的列表接口。

**本地替代（已确认）**

- 保留 `collections`、`collection_audio_items`、`audio_items` 与全部学习数据，只替换数据来源：新增「导入本地合集」，**用户直接选目录**，不引入清单文件。
- 合集名取目录名；音频按文件名自然排序；同名 `.srt` / `.vtt` / `.lrc` 自动配对（复用现有导入的同名配对规则）；缺字幕时走现有本地转录。
- 不支持、不展示远端 `remoteId`、地区镜像、难度徽标等仅远端存在的字段；`source='community'` 的历史合集保留只读，不再同步。
- 发现页（浏览远端公开合集）移除，保留「我的合集」。

### 精选播客：现状与本地替代

**现状（代码事实）**

- `GET /api/v1/featured-podcasts?cursor=` 返回 `items[]` + `nextCursor`，每项含 `id`、`applePodcastUrl`、`rssUrl`、`imageUrl`、`title`、`description`；响应原文按页缓存（`catalog.json` / `page-<hash>.json` + sha256 meta）。
- 订阅动作本身不经过后端：`subscriptionInputUrl` 优先 Apple URL、回退 RSS，交给现有 `PodcastUrlResolver` / `PodcastRepository` 直接订阅，播放与字幕都在第三方公网路径上。
- 所以自有后端只提供「精选清单」这一层。

**本地替代（已确认）**

- 内置本地 `catalog.json`（随包发布，字段与现有 `FeaturedPodcast.fromJson` 一致：`id`、`applePodcastUrl`、`rssUrl`、`imageUrl`、`title`、`description`），把「精选」变成随包目录。
- 移除远端分页刷新与 `cursor` 逻辑；本地清单不再需要网络、缓存 meta 与 sha256 校验。
- 保留用户自粘 RSS / Apple 链接的订阅入口（现有 `PodcastUrlResolver` / `PodcastRepository` 路径不变）。
- 清单更新随版本发布；不引入远程清单下载，否则又回到依赖自有后端。

### 模型资源 CDN：现状与本地替代

**现状（代码事实）**

- 是，全部走自有 CDN：`RuntimeEndpointRouter.modelCdnUri()` → `cdn.echo-loop.top` / `cdn.echo-loop.cn`，路径 `/model/<archivePath>`。
- 使用方：ASR（`silero-vad`、`whisper-tiny/base/small.en`）、Kokoro TTS、Piper TTS（多音色）、离线词典（`dict-en_zh-CN-v1` 等）、发音包（`pronunciation-v2`）。
- 每个资源在目录中固定 `archivePath` + `sha256` + 预估体积；下载后校验整包 SHA-256 → staging 解包并校验关键文件 → 写安装清单 → 原子替换（`ResourceArchiveInstaller` / `AsrArchiveInstaller`）。
- 各 manager 已有 `baseUrlOverride` 注入点，测试与自建镜像可改地址。
- 性质上是静态资源托管：无用户数据、无鉴权、无业务逻辑。

**本地替代（已确认）**

- 保留 CDN 下载。它属静态资源分发（无用户数据、无鉴权、无业务逻辑），与 RSS 同类，不构成对自有后端服务的依赖。
- 各 manager 的 `baseUrlOverride` 保持现状，便于将来指向自建镜像；「从文件导入」不在本次范围。

## 选择状态

- **已确认**：Android 主平台；供应商 OpenAI 兼容接口 + 用户自带凭据；范围仅限自有后端接口。
- **推荐**：方案 A（方案 B 已排除）。
- **未决**：见下节四项，其中供应商与模型影响可行性判断。

## 可行性问题

**优先有界问题：选定供应商与模型能否稳定产出可用结构化结果。**

- 依赖决策：是否需为该供应商调整提示词、改用 JSON Schema 模式，或更换模型。
- 已确认（官方文档）：两家均为 OpenAI 兼容 Chat Completions，支持 SSE 流式；OpenRouter 支持 `json_schema`（限特定模型/端点），DeepSeek 支持 `json_object`。
- 仍待确认：目标模型 id、速率/额度限制、各学习功能上的实际 JSON 有效性与耗时。
- 建议后续 `spike` 边界：用脱敏固定样例覆盖带上下文翻译、句子解析、单词、短语、意群、复述结构；记录有效 JSON 率、意群内容守恒、首字与总耗时。
- 决定标准：各必要功能均产出通过结构与语义校验的对象；仅部分通过则记为范围受限，不得宣布整体可行。
- 当前未执行该实验。协议层能力已由官方文档确认，但模型在具体学习任务上的输出质量与耗时仍未验证；音频端点不在本次依赖范围内。

**其余未决（需用户决定，非实验问题）**

已确定：社区合集改为目录导入；精选播客内置清单并保留自粘链接；CDN 保留；转录收敛为英语；额度 UI 只读展示（含 OpenCode Go）。

仍需确认：

1. 首选供应商与模型（OpenRouter / DeepSeek / OpenCode Go，具体模型 id）——决定 spike 的验证对象。
2. 若主供应商不是 OpenCode Go，是否仍希望保留该额度卡片（需额外填一份 Key）。

**普通实施验证**：Key 不入日志与备份、配置切换后旧回调作废、SSE 跨分片与 `[DONE]`、错误 JSON 不落缓存、取消与断流、静音与长音频转录、复述原录音保留。可沿用 `test/services/sentence_ai_api_client_test.dart`、`test/providers/sentence_ai_provider_test.dart`、`test/providers/retell_review_evaluation_provider_test.dart` 及本地转录相关测试；本轮未执行。

## 来源与保全

- 用户输入：本会话两轮。第一轮确定「本地 LLM + OpenAI 兼容 + 覆盖远程接口」；第二轮修正为 Android 主平台、供应商模型（不部署）、边界仅限自有后端接口。两点均已在「已确认决策」落文，未删除早期候选，仅记录取代关系。
- 代码基线：`5574fe21a676184ada4f562f684e312b250998e4`（应用 `1.0.44`）。工作副本由该提交的本地克隆建立，`origin` 改名为 `source-local`，未推送。
- 规则与现状：`AGENTS.md`、`CLAUDE.md`、`PLAN.md`、`TASKS.md`、`pubspec.yaml`、`pubspec.lock`。未发现 `GLOSSARY.md`、`docs/learnings/` 或既有同范围 feature 目录。
- 代码来源：`lib/services/sentence_ai_api_client.dart`、`lib/features/chatbot/{services/chat_api_client.dart,providers/chat_session_controller.dart}`、`lib/providers/sentence_ai_provider.dart`、`lib/providers/retell_review_evaluation_provider.dart`、`lib/services/dictionary/ai_dictionary_source.dart`、`lib/providers/dictionary/lookup_controller.dart`、`lib/services/backend_dio.dart`、`lib/features/subscription/providers/feature_access_provider.dart`、`lib/services/transcription_api_client.dart`、`lib/providers/local_transcription_task_provider.dart`、`lib/services/asr/{sherpa_onnx_engine.dart,asr_model_catalog.dart}`、`lib/models/{sentence_ai_result.dart,dictionary/dictionary_entry.dart,sense_group_result.dart,retell_review_evaluation.dart}`。
- 供应商与集成方案文档（2026-10-31 经 Jina Reader 与 Exa 读取；本地直连被代理 fake-IP 段拦截，未修改代理配置）：DeepSeek `https://api-docs.deepseek.com/`、`https://api-docs.deepseek.com/guides/json_mode`；OpenRouter `https://openrouter.ai/docs/api_reference/overview`、`/guides/features/structured-outputs`、`/api_reference/streaming`；OpenCode `https://opencode.ai/v2/docs/console/go`、`https://opencode.ai/v2/docs/console/harnesses`；LiteLLM `https://docs.litellm.ai/`。
- OpenCode Go 额度接口的来源是社区验证与上游 PR（`anomalyco/opencode` PR #16513、issue #16017、#18648），非 OpenCode 官方文档页；实施前应以实际 Key 复核响应形状与 403 语义。
- 证据限制：代码为静态阅读；供应商侧只读官方文档，未调用任何接口；未读取真实密钥，未运行应用、测试或实验。模型输出质量、耗时与速率限制均未验证。
- 覆盖检查：自有后端接口按清单逐项处置，第三方公网接口显式排除；未决事项未被当作已批准删除。无需额外内部附件。
