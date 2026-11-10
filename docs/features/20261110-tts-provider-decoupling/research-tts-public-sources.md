# TTS 模型公开源迁移研究笔记（Kokoro / Piper）

> 调研日期：2026-11-10（后台研究代理产出）。
> 调研状态：仓库内事实已通过文件工具核实；**8 个声明源页面在本轮会话中全部无法访问**（运行环境网络受限），因此所有页面级信息（仓库名、文件清单、commit/tag、许可原文、SHA）均标注 **[待核实]**，实施前必须按第 7 节清单独立核对。本笔记**不含任何新计算的 SHA-256**；正文出现的摘要值全部来自仓库内已记录的 CDN 归档基线。

## 0. 证据等级约定

- **【仓库已证实】**：由本仓库文件直接记载，附文件路径。
- **[待核实]**：公开渠道通行信息或预期推断，本会话未能页面复核；实施阶段逐项核实后才能写入资源目录。
- 除仓库基线外，本笔记中所有具体仓库名、tag 名、文件清单与 URL 形态均为预期值，**不是已确认事实**。

## 1. 现有 CDN 产物基线（仓库已证实）

当前下载统一走 `RuntimeEndpointRouter.modelCdnUri('/model/${archivePath}')`（`lib/config/regional_service_endpoints.dart`、`lib/services/tts/piper_model_manager.dart`），CDN 基址为 `cdn.echo-loop.top`（global）/ `cdn.echo-loop.cn`（china）。

**Kokoro**（`lib/services/tts/kokoro_model_catalog.dart`）：

| 变体 | 内部 ID | CDN 归档 | 大小（字节） | 整包 SHA-256 | 模型文件 |
| --- | --- | --- | --- | --- | --- |
| fp32 | `kokoro-en-v0_19` | `tts/kokoro-en-v0_19.tar.gz` | 313,785,757 | `d97c85ba5777bc226eca3a40312bb29dd8fd0e77546d4100abb7243b9b6ad137` | `model.onnx` |
| int8 | `kokoro-en-v0_19-int8` | `tts/kokoro-en-v0_19-int8-v2.tar.gz` | 102,614,756 | `70fd7ff687d08245f9409557f58072f43eb8a5bf8a90e98dd3bb7f60e05b4b07` | `model.int8.onnx` |

- 必需文件：`model.onnx`/`model.int8.onnx` + `voices.bin` + `tokens.txt` + `espeak-ng-data/`。
- `voices.bin` 对应 v0_19 的 11 个发音人（sid 0–10，`af_*` 美音 / `bf_*` 英音，见 `lib/services/tts/kokoro_voices.dart`）。
- **int8 身份疑点**：仓库 §7.20 记载「量化 int8 后重托管」（暗示自量化），§7.21 又引述 sherpa-onnx 原始归档名 `kokoro-int8-en-v0_19.tar.bz2`（暗示官方 int8 资产存在）。现有 `-int8-v2.tar.gz` 究竟与官方资产逐字节一致还是自量化产物，**必须下载比对方可定论**，不能仅凭文件名推断同一资源身份。

**Piper 9 个 medium 音色**（`lib/services/tts/piper_model_catalog.dart`；`scripts/piper_tts_models.manifest.txt` 数值一致）：

| 音色 ID | CDN 归档 | 大小（字节） | 整包 SHA-256 |
| --- | --- | --- | --- |
| `en_US-amy-medium` | `tts/vits-piper-en_US-amy-medium.tar.gz` | 67,347,129 | `ce4fc13a01c2b670f744c5d944469ac2c01b144f8f98ff7985d67d7402695c29` |
| `en_US-lessac-medium` | `tts/vits-piper-en_US-lessac-medium.tar.gz` | 67,358,584 | `d0fd375de4be84199813d3c69b94ebf5b14ae5c291bda61315d0307eed039065` |
| `en_US-ryan-medium` | `tts/vits-piper-en_US-ryan-medium.tar.gz` | 67,370,820 | `49e5065dd3f17c27be2d29310887dbd17b924ebfb0fc24a6f82b7e96a34a44d4` |
| `en_US-joe-medium` | `tts/vits-piper-en_US-joe-medium.tar.gz` | 67,329,430 | `c13190297212663f4371e365e239f7208ceeaae0e2d8ce5994456b42bb1e6799` |
| `en_US-kristin-medium` | `tts/vits-piper-en_US-kristin-medium.tar.gz` | 67,424,191 | `58988662c21850d05b5687043dc710a6c41bbf15814aff34e4be32c32cb377a8` |
| `en_US-hfc_female-medium` | `tts/vits-piper-en_US-hfc_female-medium.tar.gz` | 67,359,748 | `b849044f82219e2b0d990d81e75b80cecedda53608b182299beffbeadfac33f0` |
| `en_GB-alan-medium` | `tts/vits-piper-en_GB-alan-medium.tar.gz` | 67,339,791 | `29c62a69788b0533ef3ce1488eea1e1a90d6f7a0a7ece2a3ae7aadc78bd043e7` |
| `en_GB-cori-medium` | `tts/vits-piper-en_GB-cori-medium.tar.gz` | 67,431,659 | `d49b0cc0353ceabc8cb15a4781b7c4f5cb858ecad52fbfb5591b2577b21b77e8` |
| `en_GB-alba-medium` | `tts/vits-piper-en_GB-alba-medium.tar.gz` | 67,356,380 | `3f2685f7c34ec9e025a05297e294a7dad0e373acefd4a796d872e7cee1e8a696` |

- 必需文件（`lib/services/tts/piper_model_manager.dart`）：`<voice>.onnx`（按扩展名定位、排除 `.onnx.json`）+ `tokens.txt` + `espeak-ng-data/`；**无 `voices.bin`**。
- 仓库注释：9 个音色「来自 sherpa-onnx releases 的 medium 单说话人 piper 模型，重打包为 gzip（去 macOS 元数据）后托管到自家 CDN」。

**客户端硬约束**（CLAUDE.md §7.20/7.21、参考文档）：

- `archive` 包 `extractFileToDisk` 按扩展名识别，临时归档必须以 `.tar.gz` 结尾；
- bzip2 是纯 Dart 解码，解 ~100 MB 移动端过慢（原生 bunzip2 都要 >2 分钟），**不能直接分发 `.tar.bz2`**；gzip 走 `dart:io` 原生 zlib，快；
- 归档不得含 macOS xattr/AppleDouble/PAX 头（历史 FormatException 根因）；sherpa 原始归档为 Linux CI 打包、干净；
- 换归档必须「先传 CDN 再改 SHA 常量」。
- 顺带一提：`piper_model_catalog.dart`/`piper_model_manager.dart` 注释所引「§7.17」实际指向的 gzip/元数据规则现位于 §7.21，属仓库内注释引用过期，建议实施时顺手修正。

**ASR 去耦先例**（`lib/services/asr/asr_model_catalog.dart`）：

- Whisper：HF 仓库 `csukuangfj/sherpa-onnx-whisper-*.en` + 固定 commit + resolve URL 逐文件分发，逐文件 SHA-256/字节数，MIT；2026-11-07 已做 HF 与 hf-mirror 双源逐文件核对。
- Silero VAD：GitHub 发布资产 `k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx`，并明确记录「发布资产理论上可被替换，因此安装时始终逐文件校验 SHA-256」。该模式可直接复制给 espeak-ng-data 及 TTS 发布资产。

## 2. Kokoro 公开源候选

### 2.1 sherpa-onnx 官方打包（k2-fsa）— 首选，唯一满足运行时文件集的形态

- **角色**：App 现行模型的直接上游。`OfflineTts` 所需的完整文件集（`model.onnx`/`model.int8.onnx` + `voices.bin` + `tokens.txt` + `espeak-ng-data/`）只有官方打包形态存在；§7.20 明确「模型必须取自 sherpa 官方打包，不能用裸 Kokoro onnx」。
- **入口页面**：`https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html` [待核实]。
- **下载形态 A（GitHub releases）**：URL 形态 `https://github.com/k2-fsa/sherpa-onnx/releases/download/<tag>/<asset>`。发布 tag 预期为 `tts-models`，资产名预期 `kokoro-en-v0_19.tar.bz2`、`kokoro-int8-en-v0_19.tar.bz2`（后者由 §7.21 直接佐证）[均待核实，须用 GitHub API 列资产：`api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags/tts-models`]。
- **下载形态 B（HF 仓库）**：预期为 `csukuangfj/kokoro-en-v0_19`（**[待核实]**，不可当作已确认仓库名），若平铺了上述文件，resolve URL 形如 `https://huggingface.co/csukuangfj/kokoro-en-v0_19/resolve/<commit>/<file>`，与 ASR 先例同构；hf-mirror 同形换域名。
- **注意点**：`model.int8.onnx` 是否随仓携带待核实；sherpa 文档中另列的多语言 int8 版（`kokoro-int8-multi-lang-*`）是**不同模型**，不是 en-v0_19 的 int8，不要混淆。
- **许可**：sherpa-onnx 转换与发布 Apache-2.0【仓库已证实：ASR 目录同源记录】；随包 espeak-ng-data 的许可单列（见 §4）。
- **固定性**：HF 按 commit 固定（哈希待核实）；GitHub 发布资产理论可被替换 → 以自录摘要兜底（同 VAD 先例）。
- **客户端衔接**：整包 `.tar.bz2` 不能直发客户端；若走 GitHub 资产须 CI/服务端重打包为无 macOS 元数据的 gzip 后再托管（即现状路径，不满足「解除 CDN 必需依赖」）；若走 HF 逐文件则完全去 CDN。
- **int8 变体的公开源决策树**：
  1. 用 GitHub API 确认官方 en-v0_19 int8 资产是否存在、HF 仓库是否含 `model.int8.onnx`；
  2. 若存在 → 下载并与现有 `-int8-v2.tar.gz` 解包内容逐文件比对；
  3. 逐字节一致 → 同一资源身份，可在目录中直接引用公开源；不一致 → 按「如实记录差异并决策」处理（版本/缓存键变更）；
  4. 若确认无公开 int8 → 二选一：保留 CDN 现有 int8 归档（SHA 已固定），或 CI 从固定 fp32 公开源重新量化、记录量化命令与产出 SHA 后作为新版本分发。

### 2.2 hexgrad/kokoro（官方仓库）+ hexgrad/Kokoro-82M（HF 官方权重）— 仅出处/许可

- **角色**：权重与许可的法定根源；HF 仓库预期含 `kokoro-v0_19.pth`、`kokoro-v1_0.pth`、`config.json`、`voices-v1.0.bin`、`voices-v1.1.bin`、`LICENSE`、`README.md` [文件清单待核实]。
- **关键限制**：PyTorch 权重，**不是 sherpa `OfflineTts` 可加载的运行时形态**（无 ONNX/tokens.txt/voices.bin/espeak-ng-data 的 sherpa 布局）→ 仅作溯源与未来重转换上游，绝非 App 下载源。
- **许可**：权重 Apache-2.0 [待核实最终文案]。
- **固定性**：HF 按 commit；GitHub 按 tag（哈希/标签名均待核实）。

### 2.3 thewh1teagle/kokoro-onnx（转换仓库）— 仅交叉参考

- **排除为运行时源**：仓库 §7.20 已论证该 onnx 使用 misaki/phonemizer 音素化，与 sherpa `OfflineTts` 的 espeak-ng G2P 不兼容；其 release 亦无 `tokens.txt`/`espeak-ng-data` 的 sherpa 布局 [资产布局待核实]。许可预期 MIT [待核实]。仅作转换/量化对照参考。

## 3. Piper 公开源候选（9 个 medium 音色）

### 3.1 sherpa-onnx 逐音色 vits 包 — 首选运行时上游

- **出处（仓库已证实）**：`piper_model_catalog.dart` 注释「模型来自 sherpa-onnx releases 的 medium 单说话人 piper 模型，重打包为 gzip（去 macOS 元数据）后托管到自家 CDN」。
- **入口页面**：`https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/vits.html` [待核实]，从中提取 9 个音色的 HF 仓库名与 GitHub 资产链接。
- **下载形态 A（GitHub releases）**：预期资产名 `vits-piper-<id>-medium.tar.bz2`（9 个，tag 预期 `tts-models`）[逐条待核实，用 GitHub API 列 `tts-models` 资产清单]。
- **下载形态 B（HF 逐音色仓库）**：预期命名模式 `csukuangfj/vits-piper-en_US-amy-medium` 等（**[待核实]**，9 个是否齐全尤其 `en_US-hfc_female`、`en_GB-alba`、`en_GB-cori` 需确认）。若平铺 `<voice>.onnx` + `tokens.txt`，可按 commit 逐文件 resolve 分发（与 ASR 先例完全同构）。
- **许可**：sherpa-onnx 转换/打包 Apache-2.0【仓库已证实】；**权重本体许可逐音色继承 piper-voices 的音色许可**（见 3.2），不能统一写 MIT。
- **固定性**：同 2.1；每文件必有自录 SHA-256。

### 3.2 rhasspy/piper-voices（HF 官方音色集合）— 逐音色许可权威

- **角色**：**许可的权威出处**（逐音色 LICENSE/MODEL_CARD）；是否可作为文件上游需先做字节级验证（见下）。
- **布局预期**：`<lang>/<locale>/<voice>/<quality>/`，每音色目录含 `<voice>.onnx`、`<voice>.onnx.json`、MODEL_CARD、LICENSE [待核实]。
- **两个关键限制**：
  1. piper-voices 的 onnx 是 piper 自身导出，**与 sherpa vits 包内 onnx 是否逐字节一致未验证**（sherpa 转换可能改写模型元数据）；且 piper-voices **不提供 sherpa 运行时需要的 `tokens.txt`**。在字节比对与 `OfflineTts` 实际加载验证完成前，**运行时文件上游固定使用 sherpa-onnx vits 包**，piper-voices 仅作许可/溯源；验证通过并补齐 tokens.txt 来源后方可讨论作为补充候选。
  2. `en_GB-cori` 在 piper-voices 及 csukuangfj 仓库中的实际存在性与命名需特别核实（存在该音色已由仓库内 manifest 证实，但公开源路径待核实）。
- **许可（逐音色）**：**一律以音色目录 LICENSE/MODEL_CARD 原文为准**，不可默认 MIT。`en_US-hfc_female` 为社区共知的特殊许可音色（非 MIT），必须取得完整条款（含再分发与商用限制）后才能进入 UI 展示与分发决策；en_GB 三个音色同样逐条核实。
- **固定性**：HF 按 commit（哈希待核实）。

### 3.3 rhasspy/piper（软件仓库）— 仅供软件许可说明

软件许可预期 MIT [待核实]；模型许可说明是否指向 piper-voices MODEL_CARD 待核实。软件许可与模型许可须分开处理。

### 3.4 九音色核对表

注：表中「sherpa HF 仓库（预期）」全部 [待核实]，不得在核对完成前写入代码常量；许可状态以 piper-voices 内 LICENSE/MODEL_CARD 为准。

| 音色 id | piper-voices 相对路径（预期） | sherpa HF 仓库（预期） | 许可 | 状态 |
| --- | --- | --- | --- | --- |
| en_US-amy | `en/en_US/amy/medium` | `csukuangfj/vits-piper-en_US-amy-medium` | 待读 LICENSE | 待核实 |
| en_US-lessac | `en/en_US/lessac/medium` | 同上模式 | 待读 | 待核实 |
| en_US-ryan | `en/en_US/ryan/medium` | 同上模式 | 待读 | 待核实 |
| en_US-joe | `en/en_US/joe/medium` | 同上模式 | 待读 | 待核实 |
| en_US-kristin | `en/en_US/kristin/medium` | 同上模式 | 待读 | 待核实 |
| en_US-hfc_female | `en/en_US/hfc_female/medium` | 同上模式 | **特殊许可（非 MIT），条款待读** | 重点风险 |
| en_GB-alan | `en/en_GB/alan/medium` | 同上模式 | 待读 | 待核实 |
| en_GB-cori | `en/en_GB/cori/medium` | 同上模式 | 待读；**公开源路径/命名需特别核实** | 待核实 |
| en_GB-alba | `en/en_GB/alba/medium` | 同上模式 | 待读 | 待核实 |

## 4. espeak-ng-data 共享依赖

- **需求（仓库已证实）**：Kokoro 与 Piper 各需一份 `espeak-ng-data/`；现状是每个 CDN 归档各打包一份。
- **三个候选 [均待核实存在性]**：
  1. GitHub `tts-models` 资产 `espeak-ng-data.tar.bz2`（sherpa 全系 TTS 文档通用共享资产；无镜像、bz2 需重打包）；
  2. HF 仓库 `csukuangfj/espeak-ng-data`（若是目录则逐文件 resolve，若是归档则与 1 等价）；
  3. sherpa Kokoro HF 仓库内 `espeak-ng-data.tar.gz`（若存在）——gzip 可走客户端原生 zlib + 有 hf-mirror 镜像。
- **决策顺序**：实施时先核实三候选存在性；若存在可固定 commit 的 HF gzip 或目录、且解出目录树与 GitHub 资产逐字节一致 → 优先 HF 方案（镜像收益 + 免重打包）；否则以 GitHub 资产为兜底，CI 一次重打包为无 macOS 元数据 gzip（`COPYFILE_DISABLE=1` + `--no-xattrs --no-mac-metadata`），产出后先传 CDN 再写 SHA。
- **共享 or 按引擎**：须先下载现有 CDN 归档，核对 Kokoro 包内与各 Piper 包内的 espeak-ng-data 树是否逐字节一致；一致则可按 D12 作共享依赖一次安装（缺失只补依赖，不重下模型本体），不一致则按引擎各持一份并如实记录。
- **许可**：espeak-ng 上游 GPL-3.0-or-later [最终版本与文案待核实]；UI 展示须与模型许可（Apache-2.0/逐音色）分列。
- **身份风险**：与 VAD 相同，GitHub 发布资产可被替换 → 以本地自录 SHA-256 校验兜底，校验失败即拒绝安装。

## 5. hf-mirror.com 适用性

- **机制（已落地先例）**：hf-mirror 是 Hugging Face 通用镜像，resolve URL 同路径换域名即用、同 repo 同 revision 同文件摘要（`asr_model_catalog.dart` 的 `AsrDownloadSource.huggingFaceMirror`）；来源切换只改下载域名，不改受信版本与摘要。
- **适用**：全部 HF 仓库候选——Kokoro sherpa 仓库、9 个逐音色 piper 仓库、可能的 espeak-ng-data 仓库、`hexgrad/Kokoro-82M` 与 `rhasspy/piper-voices`（仅溯源/许可用途）。
- **不适用**：GitHub 发布资产（`tts-models` 各 `.tar.bz2`）。没有已核实的等价镜像；沿用 ASR 先例规则——选镜像时 HF 仓库走 hf-mirror，GitHub 资产仍回退上游地址，不猜测未核实镜像 URL。这一差异意味着 **HF 逐文件 resolve 方案的镜像收益显著优于 GitHub 整包方案**。
- **[待核验]** 目标仓库在 hf-mirror 上的实际覆盖、~300 MB 文件（Kokoro fp32）与 LFS 重定向、目录树/大文件限速表现；须对每个新仓库实际拉一次 resolve URL 确认（先例仅验证过 Whisper 三仓库）。

## 6. 推荐迁移形态（供实施参考，待清单核对后落地）

- **Kokoro**：HF resolve 逐文件（`model.onnx` / `model.int8.onnx`（若存在）/ `voices.bin` / `tokens.txt`）+ espeak-ng-data 按 §4 决策；固定 commit + 逐文件 SHA-256；镜像 = hf-mirror 同 identity。int8 按 §2.1 决策树处理。
- **Piper**：优先 9 个 `csukuangfj/vits-piper-<id>-medium` HF resolve（onnx + tokens.txt）+ 共享 espeak-ng-data；个别音色无 HF 仓库时以 GitHub `tts-models` 资产兜底（CI 重打包 gzip 后先传 CDN 再改常量）。piper-voices 仅作许可展示与溯源，字节验证通过前不作运行时源。
- **许可展示**：Kokoro 权重 Apache-2.0；sherpa-onnx 转换/打包 Apache-2.0；Piper 逐音色（以 piper-voices LICENSE 为准，hfc_female 单独标识）；espeak-ng-data GPL-3.0-or-later（单独条目）。
- **写入节奏**：清单（§7）全部完成前，不把任何预期仓库名/tag/URL 落为代码常量；完成后按「repository + revision/tag + layout + license + 逐文件 SHA/字节数 + dependencies=[espeak-ng-data]」对齐 ASR 资源目录结构回填。

## 7. 页面层面无法确认的事实 → 实施阶段独立核对清单

以下各项在本轮会话均无法确认，且部分事实即便页面可达也须独立下载验证；**全部通过后才能写入 TTS 公开资源目录**：

1. **8 个声明源页面回访**：获取 kokoro.html/vits.html 的仓库链接与资产名、releases 实际 tag/资产、HF 三仓库文件清单与可用 commit。
2. **GitHub 资产清单枚举**：releases 网页是 JS 渲染不可靠，须用 `api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags/tts-models` 列资产，确认 `kokoro-en-v0_19.tar.bz2`、`kokoro-int8-en-v0_19.tar.bz2`、`vits-piper-*.tar.bz2` ×9、`espeak-ng-data.tar.bz2` 是否存在及其内容布局。
3. **逐文件 SHA-256 与字节数**：公开源逐文件摘要须独立下载计算。注意：HF API 返回的 `lfs.sha256` 是 **LFS OID，不等于文件内容 SHA-256**；与 hf-mirror 双源下载互相比对后再写入目录（照搬 ASR 2026-11-07 双源核对做法）。
4. **与现有 CDN 归档的逐字节一致性**：下载现有 CDN 归档 → 解包 → 对包内逐文件（含 espeak-ng-data 目录树）算 SHA/字节数 → 与公开源结果比对。**不能比对整包摘要**：gzip 重打包必改整包字节，只能以解包后内容为准。
5. **Kokoro int8 身份**：官方 int8 资产/HF `model.int8.onnx` 是否存在；与现有 `-int8-v2.tar.gz` 解包内容逐字节比对，不一致则按版本/身份变更决策（见 §2.1 决策树）。
6. **逐音色许可文本**：9 个音色 LICENSE/MODEL_CARD 原文，重点提取 `en_US-hfc_female` 的特殊许可条款（含再分发/商业使用限制），en_GB 三个逐条核实；sherpa 打包是否改变许可表述。
7. **piper-voices onnx 与 sherpa vits 包 onnx 一致性**：9 个音色逐字节比对；是否可被 `OfflineTts` 直接加载。验证通过前 piper-voices 仅作许可/溯源。
8. **espeak-ng-data 三候选核实**：存在性 + 各候选解出目录树互比 + 与现有 CDN 包内树逐字节一致（决定共享一份还是按引擎两份）+ GPL 版本与文案原文。
9. **仓库卫生**：修正 `piper_model_*` 注释中过期 §7.17 引用（实际为 §7.21）。
10. **hf-mirror 实测**：目标新仓库、大文件、LFS 重定向的覆盖与限速；GitHub 资产在受限网络的可达性记录。

**实施顺序建议**：① 抓 8 页面 + GitHub API 列资产 + HF 文件清单/commit；② 上游与 hf-mirror 双源独立下载并计算逐文件 SHA；③ 与现有 CDN 归档解包内容逐文件比对；④ 决策 int8 与 espeak-ng-data 落地形态；⑤ 凡需重打包者，先传 CDN 再改 SHA 常量；⑥ 逐音色许可文案摘录；⑦ 回填 TTS 公开资源目录并切换下载源。

---

**主要局限**：本笔记中所有页面级公开信息（仓库名、文件清单、URL 形态、tag/commit）均为「预期 + 仓库历史佐证」级别，未做页面确认；第 7 节清单必须在实施前逐项完成独立核对后才能写入代码常量。
