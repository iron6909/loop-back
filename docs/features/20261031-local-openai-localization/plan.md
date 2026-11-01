# 供应商直连与本地化改造实施计划

**Goal:** 把 AI 能力改为用户自配供应商直连，其余自有后端能力本地化或停用，并保持既有学习数据可用。
**Spec:** `docs/features/20261031-local-openai-localization/spec.md`
**Approach:** 先建立与网络无关的纯逻辑层（校验、缓存键、输出模式、用量映射），再接传输层与 UI，最后做解耦与停用收尾。每个任务都能独立验证，且不依赖后续任务补齐安全或错误处理。

## Constraints

- 不新增依赖；复用现有 `dio`、`flutter_secure_storage`、`drift`、`sherpa_onnx`、`ffmpeg`。
- Android 为主要验收平台；iOS / macOS 不得因改动无法编译。
- 后续开发以本机 Flutter SDK 为准（用户选择前置依赖修复 B）；允许更新 `pubspec.lock`、`pubspec.yaml` 中必要的依赖兼容约束与对应插件生成文件。先完成前置修复，再执行 Task 1；不新增依赖。
- 不处理上游既有 yamllint 告警与 `AndroidSpeechPlatformHandler` 相关 Kotlin 告警，避免无关 diff。
- 不削弱既有测试；不得为了让新代码通过而修改既有断言。
- 真实供应商调用不进自动化测试；测试一律用注入的假 transport / 假 Dio。
- 保持 `AGENTS.md`：中文注释、类型安全（避免 `dynamic`/`as` 强转/`!`）、单文件 ≤500 行、单函数 ≤50 行。
- 缓存 schema 不变；旧缓存行保留不删除。
- 运行命令一律在仓库根目录执行。

## Review focus

- **校验绕过**：`finish_reason=length`、空正文、类型错误、意群不守恒必须判失败，不能因 HTTP 200 或 `fromJson` 不抛就落缓存。覆盖：Task 1、Task 7 的单测。
- **凭据泄漏**：Key 进日志、备份、SharedPreferences 是最高危回归。覆盖：Task 5 的存储单测 + Task 6 的请求构造断言。
- **配置切换竞态**：旧配置回调写入新配置界面。覆盖：Task 7、Task 10 的 generation 测试。
- **门控残留**：任一 AI 入口仍被登录/会员拦截。覆盖：Task 9 的 provider 测试。
- **数据破坏**：转录失败覆盖原音频、导入失败留下半成品合集。覆盖：Task 12、Task 15 的失败路径测试。

## Existing coverage

- REQ-24: 模型资源 CDN 下载与 SHA-256 校验已实现于 `lib/services/asr/asr_model_manager.dart`、`lib/services/resource_archive_installer.dart`、`lib/services/asr/asr_model_catalog.dart`；最终验证运行 `test/services/asr/asr_model_manager_test.dart` 确认未被本次改动破坏。

## Tasks

### Task 1: 六项结构化结果的严格校验器

**Covers:** REQ-6, REQ-7
**Depends on:** None
**Files:** 新增 `lib/services/provider/structured_result_validator.dart`；新增 `test/services/provider/structured_result_validator_test.dart`
**Change:** 提供按功能分派的纯函数校验：入参为功能标识、原始 JSON 对象与原文（意群需要）。先做类型检查再调用现有 `fromJson`，并对 `SenseGroupResult.fromJson` 的 `TypeError` 兜底捕获。逐项实现 spec「结果校验」表中的必填与语义规则；意群额外用 `validateSenseGroupChunks` 校验 `medium` 与 `fine`。返回成功（携带领域对象）或失败（携带失败原因枚举：`emptyBody`/`notJsonObject`/`fieldType`/`missingField`/`invalidEnum`/`notConserved`）。
**Interfaces:** `StructuredFeature` 枚举（`translation`/`analysis`/`word`/`phrase`/`senseGroups`/`retell`）；`ValidationOutcome` 密封类，后续 Task 7 消费。
**Check:** `flutter test test/services/provider/structured_result_validator_test.dart` → 全绿；每功能至少一个通过样例与一个失败样例，含意群大小写变化被拒、`medium` 为字符串被拒。

### Task 2: 配置指纹与缓存键

**Covers:** REQ-10
**Depends on:** None
**Files:** 新增 `lib/services/provider/provider_cache_key.dart`；新增 `test/services/provider/provider_cache_key_test.dart`
**Change:** 实现 `configFingerprint(baseUrl, model, promptVersion)`：对 `baseUrl|model|promptVersion` 做 sha256 取前 16 位十六进制。实现 `cacheType(feature, fingerprint, {targetLanguage})`，返回 `<feature>[:<lang>]:<fingerprint>`。Key 不参与计算。
**Interfaces:** Task 7 与既有 `SentenceAiCacheDao` 的 `type` 参数对接。
**Check:** `flutter test test/services/provider/provider_cache_key_test.dart` → 相同输入稳定、不同 model 或 promptVersion 产生不同指纹、type 格式符合约定、传入 Key 不改变结果。

### Task 3: 输出模式选择与回落判定

**Covers:** REQ-5
**Depends on:** None
**Files:** 新增 `lib/services/provider/output_mode.dart`；新增 `test/services/provider/output_mode_test.dart`
**Change:** 定义 `OutputMode { jsonSchema, jsonObject }`；实现「首选严格 Schema → 仅在明确不支持时回落一次」的判定函数：输入为当前模式与响应/错误特征（如 400 且错误体表明不支持 `response_format`），输出为下一模式或终止。明确列出**不得回落**的情形：`finish_reason=length`、空正文、非 JSON、类型错误、守恒失败。
**Check:** `flutter test test/services/provider/output_mode_test.dart` → 不支持信号触发一次回落、二次失败不再回落、`length` 与校验失败不触发回落。

### Task 4: 三家用量响应映射

**Covers:** REQ-12, REQ-14
**Depends on:** None
**Files:** 新增 `lib/services/provider/usage_models.dart`、`lib/services/provider/usage_mapper.dart`；新增 `test/services/provider/usage_mapper_test.dart`
**Change:** 定义 `UsageSnapshot`（套餐窗口列表或金额余额列表 + 范围标注 `account`/`keyBudget`）。实现三家映射：DeepSeek `balance_infos[]`（字符串金额、多币种不混加、不可解析丢弃、`is_available` 仅作状态）；OpenRouter `/credits` 与 `/key`（缺 `total_usage` 不出数、`limit_remaining=null` 记为未设预算、`effective_budget` 单独标注）；OpenCode Go 三窗口（`rate-limited` 优先、`percent=0` 丢弃 `resetsAt`、取剩余最少窗口）。
**Interfaces:** Task 10 消费。
**Check:** `flutter test test/services/provider/usage_mapper_test.dart` → 覆盖 spec 列出的全部边界，含 `percent=0`、`rate-limited`、多币种、`null` 预算、形状漂移返回空。

### Task 5: 供应商配置与凭据存储

**Covers:** REQ-1, REQ-2, REQ-3
**Depends on:** None
**Files:** 新增 `lib/services/provider/provider_config.dart`、`lib/services/provider/provider_config_store.dart`；新增 `test/services/provider/provider_config_store_test.dart`
**Change:** 定义 `ProviderKind { deepseek, openrouter, custom }` 与 `ProviderConfig`（kind、baseUrl、model、promptVersion）。Store 用 `flutter_secure_storage` 存 Key，用普通偏好存其余字段；提供 `isConfigured`、`read()`、`save()`、`clearKey()`。Base URL 校验：必须是 http/https、无内嵌账号密码。日志与 `toString` 不得包含 Key。
**Interfaces:** Task 6、7、10、11 读取；`isConfigured=false` 时上层不发请求。
**Check:** `flutter test test/services/provider/provider_config_store_test.dart` → 保存后可读、Key 只进安全存储（用假 storage 断言）、非法 URI 被拒、`toString` 不含 Key。

### Task 6: 供应商 HTTP 客户端与错误映射

**Covers:** REQ-2, REQ-25
**Depends on:** Task 5
**Files:** 新增 `lib/services/provider/provider_http_client.dart`；新增 `test/services/provider/provider_http_client_test.dart`
**Change:** 独立 `Dio` 实例：不挂 Supabase token、平台/渠道头、权益拦截器、区域路由。拼接 `{baseUrl}/chat/completions`（不自动补 `/v1`）。连接 15s / 接收 120s。按 spec 映射 401/402/404/429/5xx/超时到领域错误枚举；5xx 重试一次。对 `opencode.ai` 主机附带稳定 `x-opencode-session` 与本应用 UA，其他主机不附加。
**Check:** `flutter test test/services/provider/provider_http_client_test.dart` → 用假 adapter 断言请求 URL/头部/超时配置、错误分类、重试次数、非 Go 主机无会话头。

### Task 7: 结构化 AI 客户端本体

**Covers:** REQ-2, REQ-5, REQ-6, REQ-7, REQ-10, REQ-11
**Depends on:** Task 1, 2, 3, 5, 6
**Files:** 新增 `lib/services/provider/structured_ai_client.dart`、`structured_prompts.dart`；补充 HTTP 错误体与校验失败分类；新增 `test/services/provider/structured_ai_client_test.dart`。调用点接线并入 Task 9，与旧缓存、重试及门控清理一次完成。
**Change:** 六功能统一走「组提示词 → 发请求（Task 3 选模式）→ Task 1 校验 → 命中写缓存（Task 2 键）→ 产出单个 `isFinal=true` 帧」。带 generation 守卫：配置变更或取消时旧回调丢弃。失败不写缓存。
**Check:** `flutter test test/services/provider/structured_ai_client_test.dart` → 六功能各一条成功路径与一条校验失败路径；失败不调用 cache upsert；generation 变更后旧响应被丢弃。

### Task 8: 聊天 SSE 客户端

**Covers:** REQ-8, REQ-9
**Depends on:** Task 6
**Files:** 改造 `lib/features/chatbot/services/chat_api_client.dart`；新增 `test/features/chatbot/services/chat_api_client_sse_test.dart`
**Change:** 用标准 Chat Completions SSE：按空行分事件、`data:` 前缀、`[DONE]` 结束、UTF-8 跨分片；忽略空正文的 finish 帧；仅当见过 `finish_reason=stop` 且收到 `[DONE]` 才判完成；EOF 不算完成。用户停止时保留已累积文本。
**Check:** `flutter test test/features/chatbot/services/chat_api_client_sse_test.dart` → 正常流、尾帧含空正文、断流无 `[DONE]`、跨分片 UTF-8、停止保留文本。

### Task 9: 供应商接线并解除登录与会员门控

**Covers:** REQ-1, REQ-2, REQ-3, REQ-4, REQ-5, REQ-6, REQ-7, REQ-10, REQ-11, REQ-25
**Depends on:** Task 7, 8
**Files:** 改造 `lib/providers/sentence_ai_provider.dart`、`lib/services/sentence_ai_api_client.dart`、`lib/services/dictionary/ai_dictionary_source.dart`、`lib/providers/dictionary/lookup_controller.dart`、`lib/providers/retell_review_evaluation_provider.dart`、`lib/features/chatbot/providers/chat_session_controller.dart` 与相关 UI 门控；新增配置生命周期 provider。
**Change:** 将句子、词典与聊天入口接到 Task 7/8 客户端，共用配置身份与取消守卫，移除旧缓存重复写入和对无效结果的自动重试。移除 `isAuthenticatedProvider`、`featureAccessProvider`、`supabaseSessionProvider` 前置检查与 402 分支；保留取消、generation/session 守卫与缓存。AI 入口不再跳转 paywall。
**Check:** `flutter test test/providers/sentence_ai_provider_test.dart test/providers/retell_review_evaluation_provider_test.dart` → 未登录时调用不再被拦截；既有通过用例保持通过。

### Task 10: 用量查询服务

**Covers:** REQ-12, REQ-13, REQ-14
**Depends on:** Task 4, 6
**Files:** 新增 `lib/services/provider/usage_query_service.dart`；新增 `test/services/provider/usage_query_service_test.dart`
**Change:** 按当前配置主机选端点；60 秒缓存并合并并发刷新；失败保留上次成功值并记录时间；切换配置或 Key 时取消旧刷新并作废回调；不向未知主机发送凭据。
**Check:** `flutter test test/services/provider/usage_query_service_test.dart` → 缓存命中、并发合并、失败保留旧值、配置切换后旧结果不写回、自定义主机返回不支持。

### Task 11: AI 服务页与用量卡

**Covers:** REQ-1, REQ-12, REQ-13
**Depends on:** Task 5, 10
**Files:** 新增 `lib/features/provider_settings/screens/ai_service_screen.dart`、`lib/features/provider_settings/widgets/usage_card.dart`；改造 `lib/screens/settings_screen.dart` 增加入口；新增 `test/features/provider_settings/usage_card_test.dart`
**Change:** 按 `ui-spec.md` S1/S2 实现：供应商选择、Base URL/模型/Key 编辑、连接验证内联结果、用量卡九种状态。不使用 tooltip 传达信息；状态双通道。
**Check:** `flutter test test/features/provider_settings/usage_card_test.dart` → 各状态渲染与文案、失败保留旧值、未配置引导态。

### Task 12: 云端字幕入口改本机转录

**Covers:** REQ-15, REQ-16, REQ-18
**Depends on:** None
**Files:** 改造字幕转录入口（`lib/widgets/` 中触发转录的位置）与 `lib/providers/local_transcription_task_provider.dart` 的调用；移除 `lib/services/transcription_api_client.dart` 的调用点
**Change:** 转录入口直接走 `LocalTranscriptionTaskManager`；移除 `auto` 语言选项，仅保留英语；失败给明确错误且不破坏原音频与既有字幕。
**Check:** `flutter test test/providers/local_transcription_task_provider_test.dart` → 既有用例通过；新增失败路径不覆盖既有字幕。

### Task 13: 复述评估改本机转写加供应商

**Covers:** REQ-17
**Depends on:** Task 7
**Files:** 改造 `lib/providers/retell_review_evaluation_provider.dart`；移除 `lib/services/retell_review_audio_preparer.dart` 的云端上传用途
**Change:** 优先复用同 attempt 有效本机转写，否则独立转写（不传 VAD 路径）；转写失败不进入评估；不再走 2MB/AAC 上传合同；原录音不被覆盖。
**Check:** `flutter test test/providers/retell_review_evaluation_provider_test.dart` → 复用转写、独立转写、转写失败短路三条路径。

### Task 14: SAF 目录选择原生通道

**Covers:** REQ-19
**Depends on:** None
**Files:** 改造 `android/app/src/main/kotlin/app/echoloop/AndroidLocalAudioPicker.kt`（新增目录选择与子项枚举方法）；改造 `lib/features/audio_import/local_audio_file_picker.dart` 增加 `pickDirectory()`
**Change:** 新增 `ACTION_OPEN_DOCUMENT_TREE` 通道方法，返回目录名与直接子项（文件名、URI、大小、是否目录）；持久化读权限；不递归。误选或取消返回明确结果而非异常。
**Check:** `flutter test test/features/audio_import/local_audio_file_picker_test.dart` → 用假 channel 断言协议字段与目录过滤；真机验证留给 Final verification 的手动步骤。

### Task 15: 目录导入编排与界面

**Covers:** REQ-19
**Depends on:** Task 14
**Files:** 新增 `lib/features/audio_import/community_directory_import.dart`；改造 `lib/widgets/import_audio_sheet.dart` 与 `lib/widgets/import_audio_selection_list.dart`；新增 `test/features/audio_import/community_directory_import_test.dart`
**Change:** 目录名作合集名；`classifyImportFiles` 过滤；`matchSubtitlesForAudios` 配对；自然序写 `sortOrder`；子目录与不支持扩展名计数并在汇总展示；空目录不创建合集。
**Check:** `flutter test test/features/audio_import/community_directory_import_test.dart` → 配对、排序、忽略计数、空目录失败、全部重复的汇总。

### Task 16: 历史社区合集只读与移除发现页

**Covers:** REQ-20, REQ-21
**Depends on:** None
**Files:** 改造 `lib/features/community_collections/screens/community_collection_detail_screen.dart`、`lib/features/community_collections/widgets/community_collection_card.dart`；移除 `lib/features/community_collections/screens/discover_collections_screen.dart` 的入口
**Change:** 社区合集停止同步；卡片加「已停止同步」徽标；缺媒体行禁用并说明；移除发现页入口。
**Check:** `flutter test test/features/community_collections/` → 相关既有用例调整后通过；新增只读态与缺媒体禁用用例。

### Task 17: 随包精选播客清单

**Covers:** REQ-22
**Depends on:** None
**Files:** 新增 `assets/podcast_catalog.json`；改造 `lib/features/podcast/data/featured_podcast_service.dart` 读取随包资源
**Change:** 移除远端分页、`cursor` 与缓存 meta；保留自粘 RSS/Apple 订阅入口。
**Check:** `flutter test test/features/podcast/featured_podcast_service_test.dart` → 随包清单可解析、无网络请求。

### Task 18: 停用网盘导入、商店兜底与自更新

**Covers:** REQ-23
**Depends on:** None
**Files:** 移除 `lib/features/baidu_netdisk/` 入口与 `lib/widgets/import_audio_sheet.dart` 中的云盘来源；移除 `lib/services/app_update_checker.dart` 调用；调整 `lib/features/remote_config/`
**Change:** 移除网盘导入入口、商店网页结账兜底、`/version.json` 检查；远程配置改用本地默认值，移除失效字段。
**Check:** `flutter analyze` 无新增问题；`flutter test test/widgets/import_audio_sheet_test.dart` 通过。

## Final verification

- Run: `flutter analyze` → 无新增问题（既有告警文件不计）。
- Run: `flutter test` → 全绿。
- Run: `flutter test test/services/provider/ test/features/audio_import/` → 新增模块全绿。
- Manual（Android 真机，实施时执行）：选目录导入、缺字幕转写、历史合集缺媒体禁用播放、AI 服务页各状态。
- 说明：本轮不具备运行真实供应商调用的条件，模型质量不作为验收门槛（见 spec 证据限制）。
