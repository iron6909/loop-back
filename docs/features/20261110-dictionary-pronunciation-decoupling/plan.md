# 词典与发音库去 EchoLoop 化方案

> 定稿：2026-11-10。制品解剖与公开源核查：2026-11-10（CDN 可访问，三个归档已下载逐项解剖，见「制品解剖」；网页级事实待实施核对）。
> 状态：D1–D13 已经两轮“全部按建议”确认，方案定稿；业务代码尚未实施。
> 文档入口：[正式规格](./spec.md) · [公开源研究笔记](./research-dict-public-sources.md) · [实施任务与验收](./implementation.md) · [术语](../../../GLOSSARY.md) · ASR 先例 [方案](../20261106-asr-provider-decoupling/plan.md) · TTS 先例 [方案](../20261110-tts-provider-decoupling/plan.md)。

本次交付目标是：离线词典（zh-CN / zh-TW）与发音库改为固定公开源分发，解除对 EchoLoop 资源 CDN 的最后依赖；词典/发音数据内容不变（原样重托管），界面展示可核实的来源与许可，删除共享 CDN 配置完成域名隔离收口。词典查询、发音播放、备份恢复与偏好行为全部保留。

所有产品选择均已确定。公开源仓库的创建与上传属于操作者前置行动；实施阶段的独立下载核对（SHA 与逐文件比对）属于验证，不是尚未决定的产品范围。

## 目标与现状

用户目标：App 正常运行不再依赖 EchoLoop 任何服务。语音识别（2026-11-08）与语音合成（2026-11-10）已完成去耦；离线词典与发音库是 `cdn.echo-loop.top` / `cdn.echo-loop.cn` 的仅存使用方，本次完成后共享 CDN 配置整体删除。

关键事实：三个归档内容已在 2026-11-10 从现有 CDN 下载并解剖（详见研究笔记）。词典数据与开源 ECDICT 结构吻合；发音包音频找不到任何公开数据集指纹。最小改造方向是原样重托管内容、替换下载来源、展示真实来源与许可；重建数据或更换音频源不是达到目标的必然条件。

| 资源 | resourceId | 归档体积，约 | 解包内容 |
| --- | --- | --- | --- |
| 离线词典 zh-CN | `dict-en_zh-CN-v1` | 12.6 MB | `dict_en_zh-CN-v1.sqlite`，`words` 248,891 条 |
| 离线词典 zh-TW | `dict-en_zh-TW-v1` | 12.6 MB | `dict_en_zh-TW-v1.sqlite`，`words` 248,891 条（与 zh-CN **逐字节相同**） |
| 发音库 | `pronunciation-v2` | 41.4 MB | `pronunciation.sqlite`（`pronunciation_audio` 10,629 条，全部 us）+ `audio/*.opus` 10,629 个（约 38.2 MB） |

### 仓库证据

- [dictionary_catalog.dart](../../../lib/services/dictionary/dictionary_catalog.dart)：zh-CN / zh-TW 两个规格（resourceId、CDN 归档路径、整包 SHA-256、预计字节数）。
- [pronunciation_catalog.dart](../../../lib/services/pronunciation/pronunciation_catalog.dart)：`pronunciation-v2` 规格，CDN 归档路径 `dictionary/pronunciation-v2.zip`。
- [dictionary_download_manager.dart](../../../lib/services/dictionary_download_manager.dart)：下载地址由 `_endpointRouter.modelCdnUri(spec.archivePath)` 构造，`ResourceArchiveInstaller` 整包 SHA 校验 → staging 解包校验 → 原子发布。
- [pronunciation_library_manager.dart](../../../lib/services/pronunciation/pronunciation_library_manager.dart)：同样经 `modelCdnUri(pronunciationSpec.archivePath)` 下载，解包校验 `pronunciation.sqlite` 与全部音频引用后原子发布。
- [regional_service_endpoints.dart](../../../lib/config/regional_service_endpoints.dart)：`cdn.echo-loop.top` / `cdn.echo-loop.cn` 常量；本次完成后仅剩 API（官网）地址。
- [runtime_endpoint_router.dart](../../../lib/services/runtime_endpoint_router.dart)：`modelCdnUri` 与 CDN 区域路由在词典/发音库迁出后无调用方，随本次删除。
- [pronunciation_providers.dart](../../../lib/providers/pronunciation/pronunciation_providers.dart)：发音库状态机（未下载/下载中/安装中/就绪/失败）；[main.dart](../../../lib/main.dart) 首帧后 `ref.read(pronunciationLibraryProvider)` 触发缺失即下载；单词朗读命中离线发音优先、未命中或失败回退 TTS（`TextPlaybackController`）。
- [dictionary_settings_screen.dart](../../../lib/screens/dictionary_settings_screen.dart)：目前只有词典源与自动朗读设置，没有离线资源状态、来源与许可展示。
- [backup_service.dart](../../../lib/services/backup/backup_service.dart)：词典目录随备份（`resources/dictionary/`），发音库不随备份（可重下资产）。
- [storage_migration_service.dart](../../../lib/services/storage_migration_service.dart)：旧 `dict.db` → `dict.sqlite` 迁移先例；安装身份用统一安装清单校验。
- ASR / TTS 已建立的公开资源目录先例：固定 revision / tag、逐文件 SHA-256 与字节数、许可、hf-mirror 镜像切换与来源展示。

### 词典与发音业务链路

查词：选择文本 → 词典面板按词典源顺序查询（本地词典 → AI → 网页）；本地词典未下载时面板内展示下载/重试入口。朗读：单词优先离线发音（opus 文件），未命中、多词或播放失败回退统一 TTS（系统/Kokoro/Piper）。发音库安装后即刻可用，不阻塞学习流程。

## 制品解剖（2026-11-10 已核实）

三个归档已从现有 CDN 下载，SHA-256 与代码内目录值一致，解包解剖结论：

- 词典 sqlite 表结构 `words(word, phonetic, translation, collins, tag)`，与 ECDICT（skywind3000/ECDICT，MIT 许可）字段一致；条目数 248,891，为 ECDICT 全量（约 77 万）的筛选子集，筛选规则未知。
- zh-TW 与 zh-CN 解包后 sqlite 的 SHA-256 完全相同（`2d17d4d3…`）：两份归档内容为同一简体词典，仅 zip 压缩层不同。
- 发音包 10,629 条全部 locale=us（表允许 uk 但实际无英音）；音频为 Ogg Opus，每条 1.2–11 KB（约 1–2 秒）；命名 `word_us.opus`，带词性消歧（`_n` / `_v` / `_adj` / `_interj`）与连字符、缩写形式。
- 用特征文件名（如 `zygodactylous_us.opus`、`subject_us_n.opus`）在公开网络检索，**无任何已知数据集指纹**，来源无法核实。

完整数值（SHA、字节数、样本）见 [research-dict-public-sources.md](./research-dict-public-sources.md)。

## 外部能力核查

要点：

- **ECDICT**：MIT 许可；CSV/SQLite 双形态；字段 word/phonetic/definition/translation/pos/collins/oxford/tag 等；当前词典数据仅取其子集字段。可作为词典数据的来源标注。
- **HF 托管先例**：`iamzhangship/fluency-ecdict-offline` 以「固定版本 + 整包 SHA-256 + 来源与许可文档」模式分发 ECDICT SQLite 包，与本项目 ASR/TTS 规则同构。本项目按同样模式自建 HF 仓库托管三个归档。
- **发音音频公开源**：Forvo 全集为 CC BY-NC-SA（不可再分发）；MLCommons 多语口语词库（CC-BY 4.0）是关键词识别语料而非词典发音；Appen / LDC 为付费数据。均不构成现有发音包的来源候选；现有包来源核实失败，按 D11 处理。
- **hf-mirror**：覆盖 HF 候选仓库；本次镜像切换沿用 ASR 已落地模式（同一资源身份、明确标识镜像地址）。
- **页面级信息已核实**：仓库 `banko3/loop-back`（revision `3b3a5bef…`）已由操作者创建并上传三归档；2026-11-10 双源独立下载核对通过（整包 SHA/字节数与 CDN 原件逐字节一致），实施可直接落地为代码常量。

## 已确认范围（D1–D7）

第一轮由用户回复“全部按建议”确认。

| 编号 | 已确认问题 | 决定 |
| --- | --- | --- |
| D1 | 项目范围 | 覆盖词典 zh-CN、zh-TW 与发音库三个资源的去耦；只改分发、不改数据内容；数据重建/升级（含 zh-TW 繁体化、发音换源）另立项目 |
| D2 | 界面与来源展示 | 词典设置页新增「离线资源」区：词典逐语言展示数据来源与许可（ECDICT MIT + 托管仓库）与下载状态；发音库加状态行（来源/许可/未下载/下载中/失败重试），不再静默无感 |
| D3 | 托管位置与镜像 | 自建 Hugging Face 数据集仓库（固定 revision + 整包 SHA-256），提供 hf-mirror 镜像切换入口；**切换方式为手动**（默认 HF 主源、可切 hf-mirror，同一资源身份），复用 ASR 已落地的同一份偏好与 UI 组件，不做按地区自动默认（Q14 追加确认）；不使用 GitHub 发布资产（无已验证镜像，且本次归档为客户端可直接消费的 zip，无重打包约束） |
| D4 | 域名隔离收口 | 完成后删除 `cdn.echo-loop.top`/`cdn.echo-loop.cn` 常量与 `modelCdnUri` 整套 CDN 路由；`RuntimeEndpointRouter` 只保留官网 API 地址（社区邀请链接用） |
| D5 | 备份边界 | 保持现状：词典随备份（`resources/dictionary/`）、发音库不随备份；恢复旧备份中的词典继续有效 |
| D6 | 启动自动下载 | 发音库保留「启动后缺失即自动下载约 41 MB」的现有行为，只换来源 |
| D7 | 验收平台边界 | Android 真机优先（公开源下载、镜像切换、断网降级、备份恢复往返）；Windows 全量测试；Apple 编译与集成测试待 macOS 宿主，不虚报 |

## 已确认行为（D8–D13）

第二轮由用户回复“全部按建议”确认。以下行为与 D1–D7 共同构成实施契约。

| 编号 | 已确认问题 | 决定 |
| --- | --- | --- |
| D8 | 资源身份策略 | 三个归档**原样重托管**：内容字节不变、resourceId 不变、安装目录不变；旧安装与备份恢复继续有效，零迁移成本 |
| D9 | zh-TW 变体 | 保留两个变体原样分发、行为不变；是否合并或真正繁体化留到数据重建项目 |
| D10 | 发音包来源与许可 | 来源无法核实；仍重托管到自有仓库，界面**只标注托管仓库、不标注第三方来源与许可**（如实展示，不虚构归属） |
| D11 | 词典来源标注 | 词典设置页标注「数据来源 ECDICT（MIT 许可）+ 托管仓库」；发音库标注「托管仓库」 |
| D12 | 下载可靠性语义 | 沿用既有安装器语义：staging 校验后原子发布、失败回滚不损坏旧安装、`.part` 续传、取消、损坏安装回未安装态并给出修复入口；镜像切换只作用于下载源，不改变资源身份 |
| D13 | 交付链 | 方案定稿 → to-spec 正式规格发布 issue tracker → to-tickets 拆成可独立验收的纵向切片工单（带阻断边）→ implement；无关小清理（死 ARB 文案等）不并入本项目 |

### 设置结构

```text
词典设置
  自动朗读
  屏蔽网页词典广告
  默认词典源
  词典源启用开关
  离线资源（新增区）
    本地词典 zh-CN / zh-TW：来源与许可 + 下载状态/进度/失败重试
    发音库：来源 + 下载状态/进度/失败重试
    下载来源：HF 上游 / hf-mirror 镜像（切换项，同 ASR）
```

保留现有页面结构与交互，只新增离线资源区与来源展示；查词面板内的词典下载/重试入口保持不变。

## 配置、结果与迁移契约

### 配置的单一来源

- 词典语言选择与发音库行为无新增偏好；下载来源（上游/镜像）沿用 ASR 已落地的下载来源偏好（同一份偏好，不新建第二套）。
- 安装身份（resourceId、目录名、安装清单）不变。公开源归档与现有 CDN 归档逐文件一致时，旧安装视为同一身份、不强制重下；若实施核验发现不一致，明确记录版本变化并另行决策，不能伪称只改下载地址。
- 词典随备份、发音库不随备份的既有行为保持不变；恢复旧备份（旧 resourceId 仍为同一值）继续有效。
- 发音库启动自动下载与失败静默回退 TTS 的既有行为保持不变，仅新增设置页状态与重试入口。

### 迁移规则

| 原状态 | 升级后的处理 |
| --- | --- |
| 已安装词典 zh-CN / zh-TW 且有效 | 保留目录、ID 和安装结果；切公开源不强制重下 |
| 已安装发音库且有效 | 保留；`_removeLegacyV1` 清理逻辑不变 |
| 损坏/截断安装 | 回到未安装态，界面给修复入口（重新下载即修复） |
| 旧 `dict.db` 迁移产物 | 继续识别（同现有 storage_migration 逻辑） |
| 备份与恢复 | 行为不变：词典随备份恢复，发音库重下，恢复不触发下载 |

## 现有实现约束

- 下载地址在 dictionary/pronunciation 管理器内由 `endpointRouter.modelCdnUri` 构造；切公开源只需替换 URL 构造（HF resolve + 镜像），不重建下载器与安装器。
- 现有目录是整包归档 + 整包 SHA；重托管后仍为整包 zip，逐文件校验仅在解包校验阶段（既有 `extractAndValidate` 逻辑），公开源侧记录整包 SHA 与字节数。
- ASR 的下载来源切换偏好与 UI 组件已落地，词典/发音库复用同一来源选择状态与展示组件，不复制第二套实现。
- resourceId 同时是目录名、安装清单键与下载状态 key，必须保持；本次改名不涉及。
- 词典/发音库相关代码注释中的 Echo Loop CDN 表述随本次修正；不扩大到整款应用的更名。
- 发音库 sqlite 允许 uk 但实际全 us 是数据现状，本次不补英音（数据重建项目范围）。

## 实施顺序

### 1. 公开源核验与目录落地

- 操作者前置行动：新建 HF 数据集仓库，原样上传三个归档，固定 revision；记录仓库名、revision、归档路径与 HF 卡片来源说明（ECDICT MIT + 发音包标注策略见 ADR-0002）。
- 实施第一步逐项独立下载核对：整包 SHA-256、字节数、解包逐文件比对（与现有 CDN 归档一致才可宣称「同一身份、不重下」）。
- 落地词典/发音库公开资源目录（固定 revision、整包 SHA-256、字节数、来源与许可标注），与 ASR/TTS 目录同构。

### 2. 分发切换与安装兼容

- dictionary / pronunciation 管理器改从公开资源目录构造下载地址（HF resolve + hf-mirror 镜像切换），保留 staging 校验、原子发布、失败回滚、`.part` 续传与取消。
- 隔离 EchoLoop 域名后新安装、查词与发音播放必须可用；词典/发音正常流程不再需要该域名。

### 3. 界面来源展示与状态入口

- 词典设置页新增「离线资源」区：逐语言来源/许可与下载状态、发音库状态行与重试入口、下载来源切换（上游/镜像）。
- 新增 ARB 文案（中英文）；保持查词面板内下载/重试入口与既有交互。

### 4. 域名隔离收口

- 删除 `regional_service_endpoints.dart` 的 CDN 常量、`RuntimeEndpointRouter.modelCdnUri` 与 CDN 区域选择；`apiBaseUrl` 与官网链接保持不变。
- 配置校验与域名隔离回归：编译产物与正常流程不再出现 EchoLoop CDN 域名。

### 5. 迁移回归与备份边界

- 已装不重下、旧清单识别、损坏修复、备份恢复（词典随备份、发音库重下）回归测试。
- 每项实施任务运行定向 `flutter analyze` 与相关 unit/widget 测试；整体交付运行 `scripts/check.sh`，宿主不支持的步骤单独报告。

### 6. 设备验收

- Android 真机：公开源下载（含镜像切换）、断网查词与发音降级、备份恢复往返、域名隔离证据。
- iOS/macOS 保持编译与既有功能；正式宣称前补实机证据（待 macOS 宿主）。

## 验收边界

| 边界 | 必须保护的行为 |
| --- | --- |
| 离线资源 | 旧 ID/安装可读、旧安装继续可用、新公开源安装完整、错误哈希/中断/取消不发布坏安装、损坏安装可修复 |
| 去耦 | 隔离 EchoLoop 域名后词典下载、查词与发音朗读仍能完成；正常流程不需要该域名；CDN 配置与路由删除 |
| 界面 | 来源与许可可查（词典 ECDICT MIT + 托管仓库；发音库只标托管仓库）；发音库失败有状态与重试入口 |
| 迁移 | 已装资源不重下、备份恢复行为不变、旧 `dict.db` 迁移产物继续识别 |
| 设备 | Android 实机验证公开源下载、镜像切换、断网降级与备份恢复；现有查词与朗读行为不变 |

## 预计涉及的文件

- 公开资源目录：`lib/services/dictionary/dictionary_catalog.dart`、`lib/services/pronunciation/pronunciation_catalog.dart` 改公开源字段；或新增共用公开资源描述。
- 分发与安装：`dictionary_download_manager.dart`、`pronunciation_library_manager.dart`（URL 构造与镜像）；对应管理器与安装测试。
- 域名隔离：`lib/config/regional_service_endpoints.dart`、`lib/services/runtime_endpoint_router.dart` 及路由测试。
- 界面与文案：`lib/screens/dictionary_settings_screen.dart`、`lib/providers/pronunciation/*`；`app_en.arb` / `app_zh.arb` 及生成的 `app_localizations*.dart`。
- 文档：本方案、spec、implementation、研究笔记、ADR-0002、README、TASKS、PLAN。

## 决策与验证记录

- 用户通过 grill-with-docs 调用 grilling 与 domain-modeling：第一轮确认 D1–D7（范围、界面、托管与镜像、域名隔离、备份、启动行为、验收边界、无关清理），第二轮确认 D8–D13（原样重托管、zh-TW、发音包来源标注、词典标注、可靠性语义、交付链）；两轮均回复“全部按建议”。
- 已阅读 PLAN.md、TASKS.md、GLOSSARY.md 与词典/发音库相关源文件；GLOSSARY.md 已补充离线词典、发音库术语。
- 制品解剖由本机从现有 CDN 下载完成（三个归档 SHA 与代码内目录一致）；公开源网页级事实（ECDICT 许可与 HF 先例）经公开检索获得，待实施独立下载核对。
- 本次为文档交付，未修改业务代码、未运行 Flutter 测试或 `scripts/check.sh`；运行时测试列入实施任务。里程碑未因方案定稿而标记实现完成。
