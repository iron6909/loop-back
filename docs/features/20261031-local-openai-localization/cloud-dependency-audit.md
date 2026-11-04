# 本地化后的 EchoLoop 云端依赖排查与清理结果

- 排查日期：2026-11-05；清理完成日期：2026-11-05。
- 排查基线：`6571a89a`（当时工作区干净）。
- 依据：[spec.md](./spec.md) 的 REQ-20～REQ-24（历史社区只读、发现页移除、随包播客、停止自有后端业务请求、保留模型 CDN）。
- 范围：共享 Dart 启动、生命周期、路由、网络客户端、资源与图片加载；Android/iOS/macOS 原生入口与配置；随包清单、CI 与发布脚本。

## 结论

正常 App 流程**不再请求 EchoLoop 自有后端的业务 API**（AI、权益、配置、合集、播客、网盘、更新）。原先“实现保留、入口停用”的社区远端客户端、认证 SDK、权益与支付体系已整体删除，因此不存在“以后误接回 Provider 就恢复联网”的隐患。

App 仍会连接 EchoLoop 域名，但仅限规格明确保留的资源与网页：

- **模型与离线资源 CDN**：`https://cdn.echo-loop.top`、`https://cdn.echo-loop.cn`（REQ-24）。
- **官网帮助外链**：社群、条款、隐私页面，由用户主动点击。
- **iOS 网络权限探测**：向当前地区模型 CDN 根地址发一次原生请求，用于触发系统网络权限弹窗。

这不是“首次安装即可完全离线”，也不是“网络层禁止访问 EchoLoop 域名”。历史社区合集的封面已改为本地占位，浏览资源库不再产生隐式远端图片请求。

## 1. 保留的 EchoLoop 连接

统一资源域名由系统 Region 固定选择单一区域，无跨区回退：[regional_service_endpoints.dart](../../../lib/config/regional_service_endpoints.dart)、[runtime_endpoint_router.dart](../../../lib/services/runtime_endpoint_router.dart)。

| 用途 | 触发条件 | 判断 |
| --- | --- | --- |
| 离线词典 | 启动后检查本机资源，缺失或版本不匹配时下载 `/dictionary/…` | 保留的资源依赖；不是云端查词 API |
| 离线发音包 | 启动后自动检查，缺失时下载 `/dictionary/pronunciation-v2.zip` | 保留；下载后本机使用 |
| Whisper / Silero VAD | 用户下载转录或录音识别模型时访问 `/model/asr/*.zip` | REQ-24 保留；推理在本机 |
| Kokoro / Piper TTS | 选择引擎或音色且缺少模型时下载 `/model/tts/*.tar.gz` | REQ-24 保留；不是云端合成 |
| iOS 网络权限探测 | 每次第三方启动初始化，向模型 CDN 根地址请求一次 | 触发系统权限弹窗并记录状态，非业务 API |
| 社群 / 条款 / 隐私网页 | 用户点击后打开官网页面 | 规格保留的帮助外链 |
| 历史社区封面 | 已改为首字母占位，**不再请求** `coverUrl` / `coverUrlChina` | 本轮已阻断 |

`apiBaseUrl` 现在只被上述帮助网页入口使用：[main_shell.dart](../../../lib/router/main_shell.dart)、[study_screen.dart](../../../lib/screens/study_screen.dart)、[settings_screen.dart](../../../lib/screens/settings_screen.dart)。不再有业务客户端消费它。

## 2. 已删除的云端实现

### 2.1 社区合集远端能力

删除远端 API 客户端、catalog 缓存、加入流程、同步服务、媒体与字幕下载、发现页、公开详情页及其专属测试。旧链接仍可进入我的合集（`/discover`、`/collections/discover*` 重定向），不会出现死链。

### 2.2 认证与账号

删除 Supabase 启动闸、认证 Provider、登录/注册/账号页、Apple 与 Google 登录凭据、认证配置与 `auth.env.example`；启动流程不再有认证分支。旧 `/login*`、`/account` 路由重定向到设置页。

### 2.3 权益、套餐与支付

删除权益仓库与缓存、订阅控制器、套餐 Provider、付费墙页面、Paddle 与 RevenueCat 购买/管理服务、AI 试用额度存储、支付配置及专属测试。本机能力策略改为全部放行，[free_allowance_policy.dart](../../../lib/features/subscription/services/free_allowance_policy.dart) 保留兼容接口以维持调用点稳定。旧 `/paywall` 路由重定向到设置页。

### 2.4 共享基础设施

删除 `backendDio`、客户端标识、权益拦截器、Supabase token 协调器，以及只服务于旧深链的 `AppDeepLinkRouter`、`AppWindowService` 和 `AppStoreCountry`。

### 2.5 依赖与原生配置

- `pubspec.yaml` 移除 `app_links`、`supabase_flutter`、`sign_in_with_apple`、`google_sign_in`、`purchases_flutter`、`in_app_purchase`、`window_manager`；`flutter_cache_manager` 因代码直接调用其 API 从传递依赖改为直接声明（解析版本仍为 3.4.6）。
- Android Manifest 移除密码重置 App Links 与 `echo-loop://` 回流 Scheme；`MainActivity.kt` 删除 `google_services` 通道与 `play-services-base` 直接依赖。
- iOS `Info.plist` 移除 Paddle Scheme，`Runner.entitlements` 清空旧关联域与 Apple 登录权限；`AppDelegate.swift` 删除 StoreKit 与订阅管理通道。
- macOS `Info.plist` 移除 Scheme，Debug/Release entitlements 移除 Apple 登录权限，保留沙盒、网络、音频输入、用户选择文件与钥匙串权限。
- `ios/Podfile.lock`、`macos/Podfile.lock` 移除失效根 Pod 及其独占传递依赖（`app_links`、`GoogleSignIn`、`AppAuth`、`RevenueCat`、`PurchasesHybridCommon`、`in_app_purchase_storekit`、`sign_in_with_apple`、`window_manager`、`screen_retriever_macos` 等），其余 Pod 版本与校验和保持不变。
- CI/发布工作流停止注入 Supabase、Google 登录与 RevenueCat 变量，移除发布对 RevenueCat key 的强制检查；`.dev.env.template` 与三个发布脚本清除过时认证说明。

## 3. 保留的本地能力

删除远端能力时明确保留以下行为，避免影响已有用户数据：

- **历史社区合集仍可读取与删除**。[community_collection_repository.dart](../../../lib/features/community_collections/data/community_collection_repository.dart) 只做本地事务：移除合集关系，仅在音频不再被任何合集引用时清理学习记录、音频行和本地媒体/字幕；被共享的音频与学习数据保持不变。
- **历史封面与元数据字段保留**，仅停止 UI 联网；社区卡片使用首字母占位，播客继续使用订阅源封面。
- **备份凭据过滤保留**。[backup_service.dart](../../../lib/services/backup/backup_service.dart) 仍排除 Supabase 会话与 PKCE 前缀，避免从历史备份恢复凭据。
- **供应商错误类型保留**。`PremiumFeature`、`FeatureGate`、`AiQuotaRejection` 等仍被现有 UI 引用；供应商余额与限流由真实请求错误呈现。
- **旧入口兼容**。登录、账号、会员跳设置；发现页跳我的合集。
- **旧社区临时目录清理**迁入 [temp_cleanup_service.dart](../../../lib/services/temp_cleanup_service.dart)，只清理应用数据目录下 `tmp/community_media`。

## 4. 第三方连接（按规格保留）

用户配置的 AI 供应商（Chat Completions 与用量查询）、播客 RSS 与 Apple iTunes 搜索、网页词典、模型/词典/发音 CDN、帮助外链、存储/分享等系统能力，以及分析通道（默认 PostHog，可用编译变量覆盖主机）继续存在。这些不属于“自有后端业务 API”。

App 之外的工具仍可联网：[download_public_collections.py](../../../scripts/download_public_collections.py) 的手动公开 API 下载模式、发布脚本可选的 R2 上传与下载链接。它们不被 App 调用。

## 5. 验证

| 检查 | 结果 |
| --- | --- |
| `flutter analyze --no-pub --no-fatal-warnings --no-fatal-infos lib test` | 0 error，仅既有非致命提示 |
| 关键改动文件主动 LSP error 检查 | 无诊断 |
| 全量 `flutter test` | 见文末“最终验证结果” |
| Android dev arm64 debug APK | 构建成功（Java 17），安装启动见下 |
| 原生与构建配置校验 | YAML、内嵌 Bash/Python、原生 XML、LF、旧 SDK 缺席、Pod 锁文件保留项版本与校验和一致 |
| `git diff --check` | 通过 |

构建配置校验脚本会解析两个工作流的每个 `run` 块、校验内嵌 Python 语法、检查 CocoaPods 缓存键、解析原生 XML，并比对 Pod 锁文件：被删除的 Pod 必须缺席，保留 Pod 的版本与 `SPEC CHECKSUMS` 必须与基线逐项相同。

## 6. 限制

- 本机为 Windows：`scripts/check.sh` 中的 macOS 集成测试与 macOS 构建无法执行；Apple 原生构建、签名与真机运行未验证。
- Pod 锁文件按依赖图静态清理，未在 macOS 上重新执行 `pod install`；CocoaPods 重新解析后应复核一次。
- 未做真机抓包；结论基于代码可达性、路由与启动链分析，不等于网络层拦截保证。
- 自动化测试使用假 transport，不代表线上供应商可达性或模型质量。
- widget 测试通过不代表原生播放、录音与 SAF 行为已验证。

## 附：最终验证结果

- 全量 `flutter test --no-pub --concurrency=1`：**5192 通过、9 跳过、18 失败**。18 项失败逐项在基线 `6571a89a` 的独立工作树中复现（Windows 路径分隔符、`touch` / `bash` 宿主工具、media_kit 原生依赖缺失、macOS runner），本轮零回归；基线还多失败 1 项（发布脚本 CRLF），现已通过。
- `flutter analyze --no-pub --no-fatal-warnings --no-fatal-infos lib test integration_test`：0 error、4 warning、31 info（均为既有提示）。
- 定向回归：原生元数据 6 项、备份服务 21 项、合集本地移除 4 项、资源库历史封面与播客封面契约。
- Android：Java 17 下 `flutter build apk --debug --flavor dev --target-platform android-arm64 --no-pub` 成功（258,592,161 字节）。
- 真机（vivo V2055A / Android 14，`1.0.44`，保留原有数据）：学习页、资源库（本地合集显示首字母占位，播客仍显示订阅源封面，素材数与更新时间正常）、AI 服务页（DeepSeek 余额直连成功，Base URL / 模型 / Key 状态正确）均正常；无崩溃、无 `MissingPluginException`。日志仅有一条既有的 `FlutterSecureStorage` 解密告警，会回退到自定义加密且 Key 仍为已保存。
- 已尝试执行 `scripts/check.sh`，首轮在 Kokoro 集成测试的旧工厂签名与枚举引用处停止；修正后分别完成 analyze 与全量 test。macOS 集成测试与构建无法在 Windows 运行，脚本未全流程通过。
