# Echo Loop 供应商直连与本地化改造规格

> 后续设计更新（2026-11-07）：语音识别范围由已确认的[去 EchoLoop 化方案](../20261106-asr-provider-decoupling/plan.md)接续。ASR/VAD 将迁往公开资源来源，字幕、跟读与复述可显式选择第三方在线转写；本规格 REQ-15 / REQ-17 的“仅本机”和 REQ-24 中 ASR 沿用原 CDN 的要求属于此前阶段。新语音请求不沿用自动重试规则，文字 AI 与其他资源的约束继续有效。新方案尚未实施，以下历史交付与验证记录保留。

## Problem and goal

Echo Loop 目前把翻译、句子解析、单词/短语词典、意群、复述评估与学习助手全部交给项目自有后端（`www.echo-loop.top` / `www.echo-loop.cn`），并依赖同一后端提供登录、会员、配额、区域路由、社区合集、精选播客、网盘导入与自更新。自有后端一旦不可用，这些能力整体失效。

目标：让 AI 能力改由**用户自己配置的供应商 OpenAI 兼容接口**提供，把自有后端承载的其余能力替换为本地实现、降级或停用，使 App 在只有第三方公网接口（RSS、播客、直链、网页词典、iTunes 搜索、模型 CDN）的情况下仍可完整使用。

预期用户：现有 Echo Loop 使用者，主要在 Android 上学习英语音频材料。

## Scope and non-goals

**范围内**：自有后端业务接口的逐项处置、供应商凭据与请求契约、结果校验与缓存、随供应商切换的只读用量卡、本机转录替代云端转录、社区合集改为本地目录导入、精选播客改为随包清单、模型资源 CDN 保留。

**不做**（已确认）：

- iOS / macOS 不作为本次验收目标，但不得因改造破坏其可编译性。
- 不部署推理服务，不在设备或局域网运行本地 LLM，不引入自建网关（方案 B 已排除）。
- 不改动第三方公网接口：RSS 订阅、播客单集、音视频直链、网页词典、iTunes 搜索、商店与帮助外链、PostHog / Firebase / 友盟上报。
- 不为模型资源增加「从文件导入」入口；CDN 下载保留。
- 不引入多语言 Whisper；转录收敛为英语。
- 不保留 Echo Loop 登录、会员与 AI 配额门控。

## Design

### 选定方案

客户端直连供应商（方案 A）+ 结构化输出按能力优先严格 Schema、兼容 `json_object`（S1b）+ DeepSeek / OpenRouter 作为预设、OpenCode Go 仅作自定义兼容端点（S2b）+ Android 目录导入用原生 SAF（S3a）。

### 模块职责

| 模块 | 职责 | 边界 |
| --- | --- | --- |
| `ProviderConfigStore` | 保存供应商类型、Base URL、模型名、API Key 引用、提示词版本 | Key 只进 `flutter_secure_storage`；其余可进普通偏好 |
| `ProviderHttpClient` | 独立 Dio，拼接 `{baseUrl}/chat/completions` | 不挂 Supabase token、平台/渠道头、权益拦截器，不经区域路由 |
| `StructuredAiClient` | 六项结构化功能：组提示词、发请求、校验、产出单个终帧 | 不复用后端 NDJSON 路径增量协议 |
| `ChatStreamClient` | 学习助手 SSE 流式对话 | 复用现有 `ChatApi` 抽象与消息模型 |
| `UsageQueryService` | 按当前供应商查询套餐窗口或余额 | 只读；失败不影响推理 |
| `CommunityDirectoryImporter` | SAF 选目录 → 分类 → 配对 → 入库 | 只取直接子项 |
| `FeaturedPodcastCatalog` | 读取随包 `catalog.json` | 无网络、无缓存 meta |
| 既有 `LocalTranscriptionTaskManager` | 本机转录产出 SRT 与合成词级时间戳 | 不改转码与写库主干 |
| 既有 `SentenceAiCacheDao` | 缓存已校验结果 | schema 不变，靠 `type` 前缀隔离 |

### 数据流

1. 结构化功能：用户触发 → 读配置 → 组装提示词 → `POST {baseUrl}/chat/completions`（非流式，`response_format` 按能力选择）→ 解析 `choices[0].message.content` → 严格校验 → 命中则写缓存并产出 `isFinal=true` 领域帧；失败不写缓存、不改缓存。
2. 聊天：用户发送 → 组装历史与引用 → SSE 逐帧累积文本 → 收到 `[DONE]` 且见过 `finish_reason=stop` 才置完成。
3. 用量：进入页面或手动刷新 → 按当前配置的主机选择查询端点 → 映射为套餐窗口或金额 → 展示。
4. 目录导入：选目录 → 枚举直接子项 → 扩展名分类 → 同名配对 → 逐个复制入库 → 汇总。
5. 转录：音频 → 16 kHz WAV → 分段转录 → SRT + 合成词级时间戳 → 写库。

### 采纳的证据结论及其限制

- SAF 目录选择、直接子项遍历、按字节读取与持久化授权在 Redmi Note 7 Pro（Android 9 / API 28）上、`targetSdk 28` 与 `targetSdk 36` 两种构建下均通过，五个文件字节数与 SHA-256 逐一相符，`force-stop` 后新进程仍可读。**未**覆盖：Android 10+、其他厂商 ROM、其他 DocumentsProvider、授权撤回、取消、误选、空目录、真实媒体解码与应用内入库。
- 模型输出：DeepSeek `deepseek-flash` 单样例 6/6；OpenCode Go `deepseek-v4.1-flash` 5/6（单词任务 `finish_reason=length`）；OpenRouter `mistralai/mistral-nemo` 以 `json_object` 5/6（意群字段被写成字符串），同模型改严格 `json_schema` 单次通过。**不**构成稳定性、评分准确性或意群切分质量的保证。
- 三家 SSE 各一次均以正文 + `stop` + `[DONE]` + usage 帧结束；OpenRouter 出现 2 个无正文的 finish 帧，证明尾帧不得计为正文。
- 四个用量接口用真实 Key 各返回 200；OpenRouter 推理 Key 可读 `/credits`，同一 Key 的 `/key` 无预算字段。**不**推及其他账号或 Key 角色。
- OpenCode Go 官方定位为编码代理并监控滥用流量，要求自有 User-Agent 与稳定 `x-opencode-session`；本 App 用途是否被服务方接受未获证实。

## Interfaces and data

### 供应商配置

- 字段：`providerKind`（`deepseek` / `openrouter` / `custom`）、`baseUrl`、`model`、`apiKey`、`promptVersion`。
- `baseUrl` 语义为**直接追加 `/chat/completions` 的根路径**，不做 `/v1` 自动补全；保留用户子路径；拒绝非法 URI 与内嵌账号密码。
- 预设：DeepSeek `https://api.deepseek.com`；OpenRouter `https://openrouter.ai/api/v1`。OpenCode Go 不作为预设，用户经 `custom` 填 `https://opencode.ai/inference/go/openai/v1`。
- 模型名允许手填，不以 `/models` 可用为前提。
- 「连接验证」由用户手动触发一次最小推理请求；不复用它推断余额。

### 请求契约

- 公共：`model`、`messages`、`max_tokens`、`response_format`（按能力）、`temperature`（仅对支持该参数的端点发送）。
- DeepSeek：结构化任务发送 `thinking: {type: "disabled"}`；其 thinking 默认开启且计入输出预算。`response_format` 使用该接口支持的 `json_object`，字段结构写入系统提示词，返回值仍通过同一严格校验器。
- OpenRouter：模型声明支持结构化输出时使用 `json_schema`（`strict`、`required`、`additionalProperties: false`）并加 `provider.require_parameters: true`。
- OpenCode Go 主机：发送 `x-opencode-session`（同一会话内稳定），User-Agent 表明本应用；不得伪造其他客户端标识。
- 超时：连接 15 秒，接收 120 秒。

### 输出模式选择（S1b 判定规则）

1. 首选 `json_schema`（仅当供应商/模型声明支持）；DeepSeek 官方接口只声明 `text` / `json_object`，直接选 `json_object`，不先发送不受支持的 Schema。
2. 仅在响应明确表示不支持该输出模式时，回落一次 `json_object`；JSON 模式同时把字段结构写入系统提示词，业务校验保持不变。
3. 以下情形**一律判失败**，不得回落、不得重试成功化：`finish_reason=length`、空正文、非 JSON、JSON 顶层非对象、字段类型错误、枚举缺值、业务守恒失败。

### 结果校验

校验在反序列化之前完成，不依赖 `fromJson` 的容错：现有 `fromJson` 为展示半成品设计，能解析不等于有效；`SenseGroupResult.fromJson` 对 `medium` / `fine` 非数组会抛 `TypeError`，必须先行类型检查。

| 功能 | 必填与语义校验 |
| --- | --- |
| 翻译 | `translation` 非空 |
| 句子解析 | `grammar` 与 `listening` 非空，且每项 `point`/`note`、`phrase`/`note` 非空；`vocabulary` 各项字段非空 |
| 单词 | `headword` 非空、`meanings` 非空，每项 `partOfSpeech`/`definition` 非空且 `translation` 非空 |
| 短语 | `originalExpression` 非空、`category` 非空、`keyPoints` 非空且每项 `point` 非空、`meanings` 各项 `translation` 非空 |
| 意群 | `medium` 与 `fine` 均为非空字符串数组，且各自经 `validateSenseGroupChunks` 与原文逐字守恒 |
| 复述 | `rating` 属于枚举、`summary` 非空、`keyPoints` 非空且每项 `keyPoint` 非空与 `status` 有效、`corrections` 每项 `type` 有效且 `transcript`/`correction` 非空 |

守恒校验对大小写与词序零容忍（实测：仅大小写不同即被拒），因此提示词必须要求原样保留。

### 缓存身份

- 配置指纹 `configFingerprint` = `sha256(baseUrl|model|promptVersion)` 的前 16 位十六进制。
- 缓存 `type` 变为 `<feature>[:<targetLanguage>]:<configFingerprint>`，`textHash` 沿用现有算法。
- API Key **不进**任何键。
- 旧后端写入的缓存行保留原 `type`，因此自然不再命中，不做迁移、不清库、不删除。

### 用量数据形状

| 供应商 | 端点与凭据 | 展示规则 |
| --- | --- | --- |
| DeepSeek | `GET /user/balance`，当前推理 Key | 读 `balance_infos[]`；主值 `total_balance`，保留 `currency`；多币种分别展示不混加；可展开 `granted_balance` / `topped_up_balance`；无法解析的金额丢弃而非置 0；`is_available` 只作状态 |
| OpenRouter 账户 | `GET /api/v1/credits` | 以 USD 展示 `total_credits - total_usage`；缺 `total_usage` 时不出数；403 记为权限问题，不得标成 Key 无效 |
| OpenRouter Key | `GET /api/v1/key` | `limit_remaining` 非空时展示「Key 预算余额」并标注 `limit_reset`；无预算显示未设预算，不显示 0；`effective_budget` 存在时单独标注 |
| OpenCode Go | `GET /zen/go/v1/usage` | 三窗口 `rolling`/`weekly`/`monthly`，展示 `percent` 与 `resetsAt`；`status=rate-limited` 明确显示已限额；`percent=0` 时丢弃占位 `resetsAt`；突出剩余最少窗口 |

- 缓存 60 秒并合并并发刷新；切换配置或 Key 时取消旧刷新并作废回调。
- 只保留有限字段与查询时间，不保存原始账户响应。
- 自定义端点不识别用量能力时显示「不支持查询」，不向未知主机发送凭据。

### 目录导入契约

- 入口：我的合集右上角「+」菜单内，作为「新建合集」「订阅播客」之后的第三项「从文件夹导入」；点击直接选择目录，不提供文件或链接导入，这两项保留在合集内添加音频的流程中。移除远端发现页。
- 目录名即合集名；只读取**直接子项**，子目录忽略并提示。
- 音频扩展名白名单复用 `audioImportExtensions`；字幕为 `.srt` / `.vtt` / `.lrc`，同名优先 `srt > vtt > lrc`，复用 `matchSubtitlesForAudios`；其他扩展名忽略并在汇总中列出。
- 音频按文件名自然序写入 `collection_audio_items.sortOrder`。
- 空目录或全部被过滤时给出明确失败，不创建空合集。
- 缺字幕的音频沿用现有本地转录路径。
- 历史 `source='community'` 合集转为只读：不再发起同步；媒体未下载时禁用播放并说明原因，学习数据保留。

### 精选播客与模型资源

- 随包 `catalog.json`，字段与 `FeaturedPodcast.fromJson` 一致：`id`、`applePodcastUrl`、`rssUrl`、`imageUrl`、`title`、`description`；订阅优先 Apple URL、回退 RSS。
- 移除远端分页、`cursor` 与缓存 meta；保留用户自粘 RSS / Apple 链接入口。
- 模型资源继续经 `RuntimeEndpointRouter.modelCdnUri()` 下载，校验整包 SHA-256 后原子替换；`baseUrlOverride` 注入点保留。

### 转录与复述

- 云端字幕入口改走 `LocalTranscriptionTaskManager`：转 16 kHz WAV → 分段 → 合并短句 → SRT → 合成词级时间戳 → 写库，`transcriptSource=device`、`transcriptLanguage='en'`。
- 合成词级时间戳不等于云端真实对齐，需在 UI 上不宣称逐词精确。
- 复述评估：优先复用当前录音同 attempt 的有效本机转写，否则独立转写（**不传 VAD 路径**，避开已知 native 崩溃面）；转写失败不进入评估，不把 ASR 错误当作语言错误。
- 不复用云端上传的 AAC / 2 MB 上限合同；原录音不被覆盖；临时文件与引擎按既有生命周期清理。
- 界面只提供英语；移除 `auto`；历史 `transcriptLanguage='auto'` 仅展示、不重新生成。

## Constraints and failure behavior

### 安全与隐私

- API Key 只存 `flutter_secure_storage`；不得出现在日志、SharedPreferences、备份文件、埋点或崩溃上报中。
- 无 Key 时不发送伪造 Bearer，直接提示未配置。
- 学习原文、引用与转写只作为数据，不作为指令；提示词需明确隔离。
- 用量查询不读取浏览器 Cookie，不触发充值或续订。

### 门控与错误映射

- 移除 `isAuthenticatedProvider`、`featureAccessProvider`、`supabaseSessionProvider` 前置检查与 402 分支；保留取消、generation / session 守卫与缓存逻辑。
- 供应商错误映射：401 → Key/鉴权；402 → 供应商余额或套餐不足；404 → 地址或模型不存在；429 → 限流/额度；5xx → 重试一次后失败；超时单独提示。
- 任何映射都不得跳转到会员升级或权益对账。

### 停用的自有后端能力

| 接口 | 处置 |
| --- | --- |
| `/api/v1/stream/*` | 改由供应商直连 |
| `/api/v2/user-audio/*` | 改本机转录 |
| `/api/entitlements`、`/api/paddle/*` | 停止门控与结账 |
| `/api/v1/client/config`、区域路由 | 使用本地默认配置，单端点无回退 |
| `/api/v1/me/preferences`、`/api/v1/me/onboarding` | 仅本地保存，备份能力不变 |
| `/api/v2/collections*` | 改本地目录导入，发现页移除 |
| `/api/v1/featured-podcasts` | 改随包清单 |
| `/api/v1/netdisk/baidu/oauth/*` | 移除入口 |
| `/version.json` | 停用自更新检查 |

远程配置改用本地默认值；`cloudDriveImport`、`showStoreWebCheckoutFallback` 失去意义随之移除，`aiChatAssistant` 本地默认开启，`inAppReview` 保持默认关闭。

### 兼容与数据完整性

- 数据库 schema 不因缓存隔离而变更；旧行保留。
- 备份格式不包含 Key；恢复后需重新填写 Key。
- 切换配置不删除既有学习数据、字幕、收藏与统计。

## Acceptance

- REQ-1: 未配置供应商时，AI 功能显示未配置状态且不发出任何推理请求。
- REQ-2: 保存配置后，六项结构化功能与聊天均使用该配置的 Base URL、模型与 Key。
- REQ-3: API Key 不出现在日志、备份文件、SharedPreferences 与埋点数据中。
- REQ-4: 未登录状态下六项结构化功能与聊天均可正常完成，不出现登录或会员拦截。
- REQ-5: 供应商声明支持结构化输出时请求使用 `json_schema`；明确不支持时回落 `json_object` 一次。
- REQ-6: `finish_reason=length`、空正文、非 JSON、字段类型错误、枚举缺值或守恒失败的结果不写入缓存，并向用户显示失败。
- REQ-7: 意群结果与原文逐字守恒（含大小写与词序），不守恒即判失败且不落缓存。
- REQ-8: 聊天仅在收到 `[DONE]` 且出现过 `finish_reason=stop` 时标记完成；EOF 或断流不得标记成功。
- REQ-9: 用户停止聊天后，已显示的文本保留。
- REQ-10: 缓存键包含配置指纹与提示词版本；切换 Base URL、模型或提示词版本后旧配置缓存不再命中。
- REQ-11: 切换配置后，旧配置的在途请求与聊天上下文作废，其回调不写入新配置界面。
- REQ-12: 用量卡按当前供应商展示：Go 三窗口与已限额状态、DeepSeek 余额与币种、OpenRouter 账户余额或 Key 预算并明确标注范围。
- REQ-13: 用量查询失败时保留上次成功数据并显示更新时间；从未成功时显示暂无法获取；任何用量状态都不阻止推理请求。
- REQ-14: `percent=0` 的 Go 窗口不显示重置倒计时。
- REQ-15: 云端字幕入口改为本机转录，产出 SRT 与合成词级时间戳并写库，`transcriptSource=device`。
- REQ-16: 转录失败时给出明确错误，原音频与既有字幕不被破坏。
- REQ-17: 复述评估使用本机转写文本加供应商评估；转写失败不进入评估。
- REQ-18: 转录语言仅提供英语，`auto` 选项移除；历史 `auto` 字幕仅展示不重新生成。
- REQ-19: 用户可选本地目录导入为合集，音频按文件名自然序，同名 `.srt`/`.vtt`/`.lrc` 自动配对，子目录与不支持扩展名被忽略并提示。
- REQ-20: 历史社区合集变为只读，不再发起同步；媒体缺失时禁用播放并提示，学习数据保留。
- REQ-21: 发现页移除，仅保留我的合集。
- REQ-22: 精选播客来自随包 `catalog.json`，用户自粘 RSS / Apple 链接仍可订阅。
- REQ-23: 应用不再请求自有后端的 AI、权益、配置、合集、播客、网盘与更新接口。
- REQ-24: 模型资源仍从 CDN 下载，校验 SHA-256 后原子安装。
- REQ-25: 供应商错误按 401 / 402 / 404 / 429 / 5xx / 超时分类提示，且不跳转会员升级。

## Testing Boundary

- 纯逻辑单测：结果校验器（六功能各含通过/失败样例）、输出模式选择、缓存键构造、用量映射（含字符串金额、多币种、`null` 预算、`percent=0`、`rate-limited`、形状漂移）、SSE 分帧与尾帧、目录分类与字幕配对。
- 注入假 Dio / 假 transport：验证请求体、头部、超时与错误映射，不触网。
- Provider 级测试：`ProviderConfigStore` 的读写与 Key 不落普通存储；切换配置的 generation 作废。
- 设备验证：Android 真机上选目录导入、缺字幕转写、历史社区合集缺媒体时禁用播放。
- 真实供应商调用不在自动化测试内；模型质量不因单样例通过而作为验收条件。
- 复用并保持通过的既有测试：`test/services/sentence_ai_api_client_test.dart`、`test/providers/sentence_ai_provider_test.dart`、`test/providers/retell_review_evaluation_provider_test.dart`、`test/features/audio_import/subtitle_pairing_test.dart`、`test/providers/local_transcription_task_provider_test.dart`。

## Remaining presentation decisions

- 用量卡的布局、字段展开方式与「更新失败」的呈现位置。
- 供应商切换与自定义端点的设置页组织方式。
- 目录导入的进度、跳过与失败汇总的呈现方式。
- 历史社区合集「只读 / 媒体缺失」的状态表达。

以上由 `ui-design` 决定，不得改变本规格的行为、状态机、安全与数据完整性约束。

## Provenance and preservation

- 决策来源：`docs/features/20261031-local-openai-localization/proposal.md`（含 2026-10-31 与 2026-11-01 两次修订），用户在本轮明确确认 A + S1b + S2b + S3a 与 21 项新增决定。
- 证据来源：同目录 `spike.md` 四次运行与 `spike-live-probes.md` 复现附件；本规格只采纳其结论与限制，不复制实验日志。
- 代码基线：`5574fe21a676184ada4f562f684e312b250998e4`（应用 `1.0.44`）；产品 Android 配置 `minSdk=24`、`targetSdk=flutter.targetSdkVersion`（本机 Gradle 扩展值 36）。
- 仓库事实依据：`lib/services/sentence_ai_api_client.dart`、`lib/features/chatbot/{services/chat_api_client.dart,providers/chat_session_controller.dart,models/chat_message.dart}`、`lib/providers/{sentence_ai_provider.dart,retell_review_evaluation_provider.dart,local_transcription_task_provider.dart}`、`lib/services/dictionary/ai_dictionary_source.dart`、`lib/providers/dictionary/lookup_controller.dart`、`lib/services/{backend_dio.dart,transcription_api_client.dart,runtime_endpoint_router.dart}`、`lib/database/{tables/sentence_ai_cache.dart,daos/sentence_ai_cache_dao.dart}`、`lib/models/{sentence_ai_result.dart,dictionary/dictionary_entry.dart,sense_group_result.dart,retell_review_evaluation.dart,collection.dart}`、`lib/features/audio_import/{subtitle_pairing.dart,local_audio_file_picker.dart}`、`lib/features/podcast/{models/featured_podcast.dart,data/featured_podcast_service.dart}`、`lib/features/remote_config/remote_config.dart`、`lib/services/asr/asr_model_catalog.dart`、`android/app/src/main/kotlin/app/echoloop/AndroidLocalAudioPicker.kt`。
- 供应商契约依据：DeepSeek Chat Completions 与 Thinking Mode 文档、OpenRouter 结构化输出与流式文档、OpenCode Go 控制台文档（含 `x-opencode-session` 与用途说明）、三家余额/额度接口文档；均于 2026-10-31 至 2026-11-01 读取。
- 覆盖检查：自有后端接口按清单逐项处置，第三方公网接口显式排除；已确认的目录导入、内置播客清单、CDN 保留、英语转录、随供应商切换的只读用量卡全部落文；未决事项未被当作已批准删除。
- 已知未决但不阻塞本合同的证据缺口：Android 10+ 与异构 ROM 的 SAF 行为、模型在多轮/复杂输入下的稳定性、Go 用途适配、速率与额度上限。这些属于实施期验证与产品风险，不是待定的设计选择。
