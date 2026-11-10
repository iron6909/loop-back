# 语音合成去 EchoLoop 化方案

> 定稿：2026-11-10。公开源外部核查：2026-11-10（后台研究，页面级事实待实施核对，见「外部能力核查」）。
> 状态：D1–D13 已经两轮“全部按建议”确认，方案定稿；业务代码尚未实施。
> 文档入口：[正式规格](./spec.md) · [实施任务与验收](./implementation.md) · [术语](../../../GLOSSARY.md) · ASR 先例 [方案](../20261106-asr-provider-decoupling/plan.md) 与[公开资源目录](../../../lib/services/asr/asr_model_catalog.dart)。

本次交付目标是：保留 Kokoro 与 Piper 本地语音合成，解除 TTS 对 EchoLoop 品牌及资源 CDN 的必需依赖；界面还原真实模型名并展示公开出处与许可。引擎、音色、变体、口音偏好、已安装模型与合成缓存全部保留。

所有产品选择均已确定。具体模型资源的重新下载校验、公开源文件与现有归档的逐字节一致性属于实施验证，不是尚未决定的产品范围。

## 目标与现状

用户目标：语音合成使用可公开获取的开源模型，解除语音合成对原产品 EchoLoop 的绑定。

关键事实：两个本地合成模型已经是开源模型（Kokoro 82M 与 Piper VITS），"Echo Loop AI" 是界面名称。最小改造方向是公开模型身份、迁移资源分发、去除品牌文案；更换推理引擎或模型版本不是达到目标的必然条件。

| 当前显示名称 | 实际模型 | 内部 ID | 当前压缩包体积，约 |
| --- | --- | --- | --- |
| Echo Loop AI (Advanced) · High quality | Kokoro 82M v0_19，fp32 ONNX | `kokoro-en-v0_19` | 300 MB |
| Echo Loop AI (Advanced) · Lightweight | Kokoro 82M v0_19，int8 ONNX | `kokoro-en-v0_19-int8` | 100 MB |
| Echo Loop AI (Balanced) · 9 个音色 | Piper VITS medium 单说话人 ×9 | `en_US-amy-medium` 等 | 每个约 67 MB |

这些体积来自现有 CDN 归档，不代表公开上游逐文件下载量或安装体积。Kokoro 与 Piper 都由 sherpa-onnx `OfflineTts` 执行；公开权重与运行引擎是不同概念，不能把原始 PyTorch 权重、HF 上其他格式的导出物与 sherpa-onnx 所需的 ONNX 文件集直接互换。

### 仓库证据

- [tts_engine.dart](../../../lib/services/tts/tts_engine.dart)：`TtsEngineKind`（platform / kokoro / piper）与 `KokoroModelVariant`（fp32 / int8）；kokoro 枚举注释仍写 "Echo Loop AI Advanced"。
- [kokoro_model_catalog.dart](../../../lib/services/tts/kokoro_model_catalog.dart)：两个变体的 CDN 归档路径（`tts/kokoro-en-v0_19.tar.gz`、`tts/kokoro-en-v0_19-int8-v2.tar.gz`）、整包 SHA-256、推理文件名（`model.onnx` / `model.int8.onnx`）与 `voices.bin` / `tokens.txt` / `espeak-ng-data` 固定文件。
- [piper_model_catalog.dart](../../../lib/services/tts/piper_model_catalog.dart)：9 个音色（6 美音 + 3 英音）各自 CDN 归档路径与已回填的整包 SHA-256；注释明确「模型来自 sherpa-onnx releases 的 medium 单说话人 piper 模型，重打包后托管到自家 CDN」。
- [kokoro_voices.dart](../../../lib/services/tts/kokoro_voices.dart)：11 个发音人（sid 0–10），`af*` 美音 / `b*` 英音。
- [kokoro_model_manager.dart](../../../lib/services/tts/kokoro_model_manager.dart) 与 [piper_model_manager.dart](../../../lib/services/tts/piper_model_manager.dart)：下载地址由 `_endpointRouter.modelCdnUri('/model/${archivePath}')` 构造；整包 SHA 校验 → staging 解包校验 → 原子替换，`ReliableHttpDownloader` 支持 `.part` 续传。
- [regional_service_endpoints.dart](../../../lib/config/regional_service_endpoints.dart)：模型分发仍使用 `cdn.echo-loop.top` / `cdn.echo-loop.cn`。词典等资源也复用该路由，TTS 去耦不能直接删除共享 CDN 配置。
- [tts_settings_screen.dart](../../../lib/screens/tts_settings_screen.dart)：引擎单选、Kokoro 专属卡（变体 + 音色单行）、Piper 逐音色行、删除与管理入口；没有来源/许可展示。
- [app_en.arb](../../../lib/l10n/app_en.arb)：`ttsEngineEchoLoop` = "Echo Loop AI (Advanced)"、`ttsEnginePiper` = "Echo Loop AI (Balanced)"、`ttsDeleteModelConfirm` = "Delete the Echo Loop voice model? …"、`ttsDownloadedModelsTitle` = "Downloaded Echo Loop models"、`ttsModelHighQuality` / `ttsModelLite`。
- [tts_settings_provider.dart](../../../lib/providers/tts/tts_settings_provider.dart)：偏好键 `tts_engine`（存 enum name，遗留 `echoLoop` 值迁移到 kokoro）、`tts_kokoro_variant`、`tts_kokoro_voice_us/uk`、`tts_piper_voice_us/uk`；新装默认 kokoro + fp32。
- [asr_model_catalog.dart](../../../lib/services/asr/asr_model_catalog.dart)：ASR 已建立的公开资源目录先例——HF resolve 固定 revision、逐文件 SHA-256/字节数、许可、hf-mirror 镜像与 GitHub 发布资产布局、来源切换与许可展示。
- [tts_cache_store.dart](../../../lib/services/tts/tts_cache_store.dart)：合成缓存键含 voiceId 与 modelTag；模型文件身份不变则缓存持续有效。

### TTS 业务链路

单词与例句发音朗读（单词卡 Pronounce、词典、精听等）经统一 TTS 协调器：`文本+参数 → cacheKey → 查缓存 → 命中直接播 / 未命中引擎合成产文件并入库 → 播放文件`。设置页可见期间执行音色试听预热。平台 TTS（flutter_tts）无模型下载，不在本次范围。

## 外部能力核查

完整笔记见 [research-tts-public-sources.md](./research-tts-public-sources.md)（2026-11-10）。要点：

- **现有 CDN 基线（仓库已证实）**：Kokoro fp32 归档 313,785,757 字节（SHA `d97c…`）、int8 归档 102,614,756 字节（SHA `70fd…`）；9 个 Piper 音色各约 67 MB，整包 SHA 均已回填。比对只能以解包后逐文件内容为准：gzip 重打包必然改变整包字节。
- **Kokoro 首选公开源**：sherpa-onnx 官方打包（k2-fsa）是唯一满足运行时文件集（`model.onnx`/`model.int8.onnx` + `voices.bin` + `tokens.txt` + `espeak-ng-data/`）的形态。HF 仓库预期 `csukuangfj/kokoro-en-v0_19`，GitHub `tts-models` 发布资产预期 `kokoro-en-v0_19.tar.bz2` / `kokoro-int8-en-v0_19.tar.bz2`——全部待核实。hexgrad/Kokoro-82M 是权重与许可的法定根源（Apache-2.0），但不是可加载的运行时形态；thewh1teagle/kokoro-onnx 与 espeak G2P 不兼容，排除为运行时源。
- **Piper 首选公开源**：sherpa-onnx 逐音色 vits 包（HF 逐音色仓库优先，GitHub `tts-models` 资产兜底）；rhasspy/piper-voices 是逐音色许可的权威出处（`hfc_female` 为社区共知特殊许可，条款必须单独核实），其 onnx 与 sherpa 包是否逐字节一致未验证，字节验证通过前不作运行时源。
- **espeak-ng-data 共享依赖**：三个候选（GitHub `espeak-ng-data.tar.bz2`、HF `csukuangfj/espeak-ng-data`、sherpa Kokoro HF 仓库内 `espeak-ng-data.tar.gz`）均待核实；优先可固定 commit 的 HF 形态（镜像收益）。Kokoro 包内与 Piper 包内该目录树是否一致须下载比对后决定共享一份还是按引擎各持一份。
- **客户端硬约束**：归档必须是 gzip（bzip2 纯 Dart 解码在移动端过慢）、不含 macOS xattr/PAX 头；GitHub 的 `.tar.bz2` 资产不能直发客户端，仅在没有 HF 形态时兜底重打包。
- **hf-mirror**：覆盖全部 HF 候选；GitHub 发布资产无已核实镜像，选镜像时仍走上游（D8 已确认）。
- **int8 身份决策树**：核实官方 int8 资产/HF `model.int8.onnx` 存在性 → 下载与现有 `-int8-v2.tar.gz` 解包内容逐文件比对 → 一致则同一身份直接引用公开源；不一致或无公开 int8 则如实记录差异并按「保留 CDN 归档（SHA 已固定）」或「从固定公开 fp32 重新量化并记录命令与产出 SHA」决策。
- **页面级信息全部待核实**：研究运行环境无法访问任何公开源页面，实施第一步是逐项完成笔记第 7 节核对清单，全部通过前不把预期仓库名/tag/URL 落为代码常量。

## 已确认范围（D1–D7）

第一轮由用户回复“全部按建议”确认。

| 编号 | 已确认问题 | 决定 |
| --- | --- | --- |
| D1 | 本地去耦是否覆盖品牌与整个 TTS 资源分发，且继续使用现有公开模型？ | 保留 Kokoro/Piper 与 sherpa-onnx，移除 EchoLoop 品牌及 TTS 对 EchoLoop CDN 的必需依赖；保留内部 ID、已装模型、合成缓存与偏好 |
| D2 | 是否保持现有模型版本不变？ | 保持 kokoro-en-v0_19 两个变体与现有 9 个 Piper 音色，不升级版本；升级另立任务 |
| D3 | 公开源采用什么规则？ | 完全复用 ASR 已确认规则：固定 revision/发布 tag + 逐文件 SHA-256 + 字节数 + 许可；HF resolve 优先并支持 hf-mirror.com 镜像切换；GitHub 发布资产只在上游无镜像时使用且不猜测镜像地址；设置页展示真实来源与许可 |
| D4 | 界面品牌如何改？ | 引擎显示名改为 Kokoro / Piper，去掉 Echo Loop 前缀；删除/管理弹窗文案同步去品牌化；展示来源与许可 |
| D5 | 迁移兼容到什么程度？ | 保留内部 ID、安装目录、已装模型、合成缓存与全部偏好；合法旧安装继续识别、不强制重下；损坏/截断安装回到未安装态并给出修复入口；新装默认引擎与默认音色不变 |
| D6 | 验收平台边界？ | Android 真机优先；iOS/macOS 保持可编译与既有功能，正式宣称前补实机证据 |
| D7 | 本次范围外？ | 不拆词典等仍走共享 CDN 路由的资源（另行立项）；不新增在线 TTS、自定义模型导入或任意下载 URL |

## 已确认行为（D8–D13）

第二轮由用户回复“全部按建议”确认。以下行为与 D1–D7 共同构成实施契约。

| 编号 | 已确认问题 | 决定 |
| --- | --- | --- |
| D8 | 下载来源切换 UI | 语音合成设置页提供与 ASR 同款的「公开上游 / hf-mirror.com」来源切换项；只作用于有镜像的资源，GitHub 发布资产在选镜像时仍走上游地址、不猜镜像 |
| D9 | Kokoro 变体展示名 | 改为真实精度名「Full precision (fp32)」/「Quantized (int8)」，保留大小辅助文案（约 300 MB / 100 MB），取代 High quality / Lightweight |
| D10 | Piper 逐音色来源与许可 | 逐音色展示出处与许可（音色行或下载入口）；实施核验发现 9 个音色同源同许可时可合并展示 |
| D11 | 管理文案去品牌 | 删除确认与管理标题改为真实名称文案（如 "Delete the {model} voice model?"、"Downloaded models"），不改变删除交互与保护逻辑 |
| D12 | 下载可靠性语义 | 沿用 staging 校验后原子发布、失败回滚不损坏旧安装、`.part` 续传、取消、损坏安装回未安装态；整包 tar.gz 还是逐文件下载由上游实际形态决定；Kokoro/Piper 共享的 `espeak-ng-data` 按共享依赖处理，缺失只补该依赖 |
| D13 | 交付链 | 方案定稿 → to-spec 正式规格发布 issue tracker → to-tickets 拆成可独立验收的纵向切片工单（带阻断边） |

### 设置结构

```text
语音合成
  合成引擎
    系统语音（非 Android）
    Piper
    Kokoro
  Kokoro 专属
    模型变体：Full precision (fp32) · 约 300 MB / Quantized (int8) · 约 100 MB
    音色（单行展开选择，音色名自带口音）
  Piper 专属
    逐音色行：下载状态 + 来源/许可 + 试听/选择
  下载来源：公开上游 / hf-mirror.com（有镜像的资源）
  已下载模型管理：删除（真实名称文案）
```

保留现有页面结构与交互（引擎单选、变体卡、音色底部弹层、删除保护、预热试听），只改文案、增加来源/许可展示与来源切换项。

## 配置、结果与迁移契约

### 配置的单一来源

- 引擎、音色、变体、口音偏好全部保留；SP 键与值稳定（enum name / 音色 id），品牌改名不触及存储。
- 安装身份（资源 ID、目录名、缓存键 voiceId/modelTag）不变。公开源文件与旧归档逐文件一致时，旧安装视为同一身份、不强制重下；若实施核验发现不一致，明确记录版本变化并另行决策，不能伪称只改下载地址。
- 新装默认保持不变：kokoro 引擎 + fp32 变体 + 默认音色（Kokoro 美音 `af_sarah` / 英音 `bf_emma`；Piper 美音 `amy` / 英音 `alan`）。
- TTS 模型是可重下资产，不参与备份；偏好随备份的既有行为保持不变。

### 迁移规则

| 原状态 | 升级后的处理 |
| --- | --- |
| 已安装 Kokoro 变体 / Piper 音色且有效 | 保留目录、ID 和安装结果；切公开源不强制重下 |
| 历史归档安装清单 | 继续识别（同 ASR 旧安装兼容）；合法缓存不重下 |
| 损坏/截断安装 | 回到未安装态，界面给修复入口（重新下载即修复） |
| 引擎/音色/变体/口音偏好 | 全部保留；Android/Apple 平台规则不变 |
| 合成缓存 | 缓存键与模型文件身份不变，继续有效；不因品牌改名清缓存 |
| 备份与恢复 | 行为不变：偏好随备份，模型重下，恢复不触发下载 |

## 现有实现约束

- 下载地址在 kokoro/piper 管理器内由 `endpointRouter.modelCdnUri` 构造，测试已有 `baseUrlOverride` 钩子；切公开源只需替换 URL 构造与校验形态，不重建下载器与安装器。
- 现有目录是整包归档 + 整包 SHA；若公开源为 HF 平铺文件，需按 ASR 模式改逐文件下载 + 逐文件 SHA，staging 与原子发布语义保持不变。
- ASR 公开资源目录是 ASR 命名空间（`Asr*` 前缀）。TTS 优先抽取通用公开资源描述（下载源、目录布局、文件摘要）供两边共用，避免两套实现漂移；若抽取会扰动已落地的 ASR 行为，则 TTS 独立同构实现一份。
- `espeak-ng-data` 是 Kokoro 与 Piper 共享依赖，公开源中按共享资源处理：缺失只补该依赖，不重下模型本体（同 ASR 共享 VAD）。
- 变体 id 与 Piper 音色 id 同时是目录名、缓存键与下载状态 key，必须保持；品牌改名不能改 ID。
- 平台 TTS 不下载模型，不进入公开资源目录；"Coming soon" 残留文案可在本次顺带清理。
- TTS 相关代码注释中的 Echo Loop 品牌名随本次修正；不扩大到整款应用的更名。

## 实施顺序

### 1. 公开源核验与目录落地

- 完成后台研究：对 Kokoro（官方权重、ONNX 转换仓库、sherpa-onnx 发布）与 Piper（官方音色集合、sherpa-onnx 逐音色模型）逐候选记录文件布局、许可与固定 revision/发布 tag。
- 独立下载核对：目标文件与现有归档逐文件 SHA-256/字节数一致才可宣称"同一身份、不重下"；不一致则如实记录差异并决策。
- 落地 TTS 公开资源目录（固定 revision/tag、逐文件摘要、字节数、许可、依赖），与 ASR 目录同构或共用抽象。

### 2. 分发切换与安装兼容

- kokoro/piper 管理器改从公开资源目录构造下载地址（HF resolve 或 GitHub 发布资产），保留 staging 校验、原子发布、失败回滚、`.part` 续传与取消。
- `espeak-ng-data` 按共享依赖安装；旧安装缺失时只补该依赖。
- 旧归档安装清单继续识别；损坏安装回到未安装态并可修复。
- 隔离 EchoLoop 域名后新安装与合成必须可用；TTS 正常流程不再需要该域名。

### 3. 界面去品牌与来源展示

- ARB 文案：引擎名 Kokoro / Piper、变体名 Full precision (fp32) / Quantized (int8)、删除确认与管理标题真实名称。
- 设置页增加下载来源切换（上游/镜像）与来源、许可展示（Piper 逐音色）。
- 保持删除保护、试听预热、下载进度/取消/错误分类等既有交互。

### 4. 迁移回归与备份边界

- 已装不重下、旧清单识别、损坏修复、缓存有效性、偏好保留与备份恢复回归测试。
- 每项实施任务运行定向 `flutter analyze` 与相关 unit/widget 测试；整体交付运行 `scripts/check.sh`，宿主不支持的步骤单独报告。

### 5. 设备验收

- Android 真机：公开源下载（含镜像切换）、域名隔离后合成与试听、损坏安装修复入口。
- iOS/macOS 保持编译与既有功能；正式宣称前补实机证据。

## 验收边界

| 边界 | 必须保护的行为 |
| --- | --- |
| 本地模型 | 旧 ID/偏好可读、旧安装继续可用、新公开源安装完整、espeak 共享依赖缺失只补依赖、错误哈希/中断/取消不发布坏模型 |
| 去耦 | 隔离 EchoLoop 域名后新安装和合成仍能完成；TTS 正常流程不需要该域名 |
| 界面 | 无 "Echo Loop" 品牌文案残留；变体名如实显示 fp32/int8；来源与许可可查 |
| 迁移 | 已装模型不重下、偏好与缓存保留、损坏安装修复、备份恢复行为不变 |
| 设备 | Android 实机验证公开源下载、合成与试听；现有平台 TTS 行为不变 |

## 预计涉及的文件

- 公开资源目录：`lib/services/tts/` 新增公开源目录（或泛化 `lib/services/asr/asr_model_catalog.dart` 共用抽象）；`kokoro_model_catalog.dart`、`piper_model_catalog.dart` 的 CDN 归档字段替换。
- 分发与安装：`kokoro_model_manager.dart`、`piper_model_manager.dart`；`resource_install_manifest.dart` 的兼容路径；对应管理器与安装测试。
- 界面与文案：`lib/screens/tts_settings_screen.dart`、`lib/providers/tts/*`（来源状态）；`app_en.arb` / `app_zh.arb` 及生成的 `app_localizations*.dart`。
- 文档：本方案、spec、implementation、README 的模型说明、TASKS、PLAN。

## 决策与验证记录

- 用户通过 grill-with-docs 调用 grilling 与 domain-modeling：第一轮确认 D1–D7（目标范围、模型版本、公开源规则、界面品牌、迁移兼容、平台边界、范围外），第二轮确认 D8–D13（来源切换 UI、变体展示名、逐音色许可、管理文案、可靠性语义、交付链）；两轮均回复“全部按建议”。
- 已阅读 PLAN.md、TASKS.md、GLOSSARY.md 与 TTS 相关源文件；GLOSSARY.md 已补充语音合成、合成引擎、音色、模型变体术语。
- 外部能力核查由后台研究完成，资料时点与结论见「外部能力核查」；逐字节一致性与 SHA-256 属于实施阶段独立下载核对。
- 本次为文档交付，未下载模型权重、未运行 Flutter 测试或 `scripts/check.sh`；运行时测试列入实施任务。里程碑未因方案定稿而标记实现完成。
