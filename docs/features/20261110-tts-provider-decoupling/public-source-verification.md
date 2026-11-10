# Kokoro 公开源核验记录（issue #21）

> 核验日期：2026-11-10。本记录覆盖研究笔记[第 7 节](./research-tts-public-sources.md)核对清单 1–5、8（本票职责）；Piper 逐音色（清单 6、7）留给 #22。
> 核验方式：GitHub 发布资产经 `api.github.com` 枚举；Hugging Face 经 `huggingface.co/api` 与 `/resolve` 实测；现有 CDN 归档与公开源均独立下载，解包后**逐文件**计算 SHA-256 与字节数比对。所有摘要均为本次独立计算，不采用整包摘要（gzip 重打包必改整包字节）。

## 结论速览

- **Kokoro fp32 / int8 两变体的唯一官方固定公开源是 `k2-fsa/sherpa-onnx` 的 `tts-models` 发布资产（`.tar.bz2`）**，现有 CDN 归档解包内容与官方资产逐文件一致。
- **int8 身份**：现有 `kokoro-en-v0_19-int8-v2.tar.gz` 与官方 `kokoro-int8-en-v0_19.tar.bz2` 解包内容逐文件一致（仅官方多一个 `README.md`）→ **同一资源身份**，可直接引用公开源（按 §2.1 决策树“一致则同一身份”）。
- **espeak-ng-data**：三候选里 `espeak-ng-data.tar.bz2` 与 `espeak-ng-data.zip` 均存在且解出 355 个文件逐字节一致；Kokoro 包内 `espeak-ng-data/` 与独立资产逐字节一致 → 按 D12 作**共享依赖一次安装**。
- **阻断**：Kokoro 运行时文件（`model.onnx` / `model.int8.onnx`）没有客户端可直接消费的官方固定公开源——官方 HF 仓库 `csukuangfj/kokoro-en-v0_19` 为空仓库，官方发布只有 `.tar.bz2`（客户端 bzip2 纯 Dart 解码过慢，不可直发）。分发形态选择见文末「决策点」。

## 1. 文档页回访（清单 1）

- `k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html` 可达。
- `kokoro-en-v0_19`（English, 11 speakers）官方下载命令为
  `wget https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-en-v0_19.tar.bz2`。
- 官方包布局（页面 `ls -lh` 节）：`LICENSE`(11K)、`README.md`(235B)、`espeak-ng-data/`(目录)、`model.onnx`(330M)、`tokens.txt`(1.1K)、`voices.bin`(5.5M)。
- 页面**未列** `kokoro-int8-en-v0_19.tar.bz2` 的下载链接，但该资产在 GitHub API 枚举中存在（见 §2）。
- 页面提及 ONNX 来自 `thewh1teagle/kokoro-onnx` 发布资产并加元数据，与 `hexgrad/Kokoro-82M` 为溯源出处；二者都不是 sherpa `OfflineTts` 可加载形态，仅作溯源。

## 2. GitHub `tts-models` 发布资产枚举（清单 2）

`GET https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags/tts-models`（共 646 个资产）。与本票相关：

| 资产名 | 大小（字节） |
| --- | --- |
| `kokoro-en-v0_19.tar.bz2` | 319,625,534 |
| `kokoro-int8-en-v0_19.tar.bz2` | 103,248,205 |
| `espeak-ng-data.tar.bz2` | 7,252,012 |
| `espeak-ng-data.zip` | 9,037,020 |

Piper 9 音色（供 #22）：`vits-piper-en_US-amy/lessac/ryan/joe/kristin/hfc_female-medium.tar.bz2` 与 `en_GB-alan/cori/alba-medium.tar.bz2` 全部存在，大小约 67.1–67.3 MB（`en_GB-cori` 67,257,412）。

## 3. 逐文件 SHA-256 与字节数（清单 3）

双源独立下载：公开上游（github.com / huggingface.co）与 hf-mirror.com 对同一 revision/文件返回相同字节（HF 平铺文件经 LFS `oid` 与独立内容摘要比对一致）。关键文件（解包后逐文件内容摘要）：

| 文件 | 字节数 | SHA-256（内容） |
| --- | --- | --- |
| `model.onnx`（fp32） | 345,555,491 | `10ff414106a038ce7e9e0126c6461e4dc8a86efaa89dc91d2009d69fe635e339` |
| `model.int8.onnx`（int8） | 134,186,977 | `e0530c5031c03c5dc957edfc6d72582c2246e9b4566643ff67eeb03610c11641` |
| `voices.bin`（两变体共用） | 5,755,904 | `a372c67b056ef0b695c375d39b99630d23fb07ad4c8d87aa32a19a62fca523ad` |
| `tokens.txt`（两变体共用） | 1,078 | `4f31c71282d14af4e926cd12462078fe9d20d00c589e63fe2750a8f56d6d7f7b` |
| `LICENSE`（sherpa 打包） | 11,358 | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |

> 注：HF 平铺文件的 `lfs.oid`（如 `abastian/kokoro-en-v0_19` 的 `model.onnx`）与上表内容 SHA-256 完全一致；`README.md` 大小 135 字节，`config.json` 111 字节。

## 4. 与现有 CDN 归档逐文件比对（清单 4）

CDN 归档（`cdn.echo-loop.top/model/tts/...`）与公开源解包后**逐文件**比对（非整包摘要）：

| 对比 | 结果 |
| --- | --- |
| CDN `kokoro-en-v0_19.tar.gz`（313,785,757 B） vs 官方 `kokoro-en-v0_19.tar.bz2` | 360/360 文件一致（SHA-256 + 字节数） |
| CDN `kokoro-en-v0_19-int8-v2.tar.gz`（102,614,756 B） vs 官方 `kokoro-int8-en-v0_19.tar.bz2` | 359/359 共同文件一致；唯一差异是官方多 `README.md` |

布局差异：官方 `.tar.bz2` 顶层为 `kokoro-en-v0_19/` / `kokoro-int8-en-v0_19/` 目录；CDN fp32 同为 `kokoro-en-v0_19/`，CDN int8 则直接平铺在根（无顶层目录）。文件内容不受影响。

## 5. Kokoro int8 身份（清单 5，按 §2.1 决策树）

1. 官方 en-v0_19 int8 资产存在：`kokoro-int8-en-v0_19.tar.bz2`（103,248,205 B，GitHub API 已确认）。
2. 下载并与现有 `-int8-v2.tar.gz` 解包内容逐文件比对：**359/359 共同文件逐字节一致**（`model.int8.onnx` 134,186,977 B、`voices.bin`、`tokens.txt`、`espeak-ng-data/` 355 文件、`LICENSE` 全部一致）。
3. 结论：**同一资源身份**。现有 int8 归档就是官方 sherpa int8 资产的 gzip 重打包（省略 `README.md`），可直接引用公开源，无需重新量化，不产生版本/缓存键变更。

## 6. espeak-ng-data 候选核实（清单 8）

三个候选：

| 候选 | 存在性 | 说明 |
| --- | --- | --- |
| GitHub `espeak-ng-data.tar.bz2` | ✅ 存在（7,252,012 B） | 355 文件 |
| GitHub `espeak-ng-data.zip` | ✅ 存在（9,037,020 B） | 355 文件，与 `.tar.bz2` 解出内容逐字节一致 |
| HF `csukuangfj/espeak-ng-data` | ❌ 不存在（models/datasets 均无此仓库） | — |

补充发现：`csukuangfj/kokoro-multi-lang-v1_0`（官方 HF）内有平铺 `espeak-ng-data/` 目录（355 文件），但捆绑在 350 MB 的多语言模型仓库里，不作独立 espeak 来源。

比对结论：

- `espeak-ng-data.tar.bz2` 与 `espeak-ng-data.zip` 解出 355 文件逐字节一致。
- Kokoro fp32/int8 包内 `espeak-ng-data/`（355 文件）与独立 `espeak-ng-data.tar.bz2` 逐字节一致。
- **决策**：espeak-ng-data 是 Kokoro 与 Piper 的共享依赖，全系同一目录树 → 按 D12 作共享资源一次安装，缺失只补该依赖。
- 客户端形态：`espeak-ng-data.zip` 是 deflate 压缩、可由客户端直接消费；`espeak-ng-data.tar.bz2` 是 bzip2、不可直发客户端。
- 落地形态（本票）：官方 `espeak-ng-data.zip` 重打包为 `espeak-ng-data.tar.gz`（gzip、无 macOS xattr/PAX 元数据、文件根级平铺），整包 SHA-256 `6ebdff81e71e67e6cc4caac37a28ebfe38b364db5cbac66746efc94403abb8a2`（8,986,848 字节）。

## 7. Hugging Face 仓库核对

| 仓库 | 状态 |
| --- | --- |
| `csukuangfj/kokoro-en-v0_19`（研究预期） | 存在但**空仓库**：`main`（commit `fdc82d75afe8db3198ed77a39458b019b1fd17fb`）仅 `.gitattributes`，无任何模型文件 |
| `abastian/kokoro-en-v0_19`（第三方） | commit `bdf3e07b7314ee4373747d18b52c89d95069e68f`，平铺 `model.onnx`/`voices.bin`/`tokens.txt`/`LICENSE`/`config.json`，逐字节与官方一致，但**缺 espeak-ng-data** |
| `RuiSumida/sherpa-onnx-kokoro-int8-en-v0_19`（第三方） | commit `f011dacb2bfae2f981210f3c19ca2972b5e5c290`，平铺 `model.onnx`/`voices.bin`，逐字节与官方 int8 一致，但**缺 tokens.txt 与 espeak-ng-data** |

结论：没有官方（csukuangfj）平铺 Kokoro en-v0_19 仓库；第三方仓库仅部分文件、且非权威出处，不能作为“固定公开源”直接落地。

## 8. 分发形态决策（已定，托管位置已确认）

决策：将官方 `.tar.bz2` 重打包为 gzip 后发布到固定公开位置（方案 A）。三个 gzip 归档整包 SHA：

| 资产 | 整包 SHA-256 |
| --- | --- |
| `kokoro-en-v0_19.tar.gz` | `d97c85ba5777bc226eca3a40312bb29dd8fd0e77546d4100abb7243b9b6ad137` |
| `kokoro-en-v0_19-int8-v2.tar.gz` | `70fd7ff687d08245f9409557f58072f43eb8a5bf8a90e98dd3bb7f60e05b4b07` |
| `espeak-ng-data.tar.gz` | `6ebdff81e71e67e6cc4caac37a28ebfe38b364db5cbac66746efc94403abb8a2` |

> 最终托管位置已确认并完成上传：公开仓库 `iron6909/loop-back-models`（tag `tts-models`），三个 gzip 归档匿名下载均已验证 HTTP 200。代码常量 repository = `iron6909/loop-back-models`。

官方固定公开源只有 `kokoro-en-v0_19.tar.bz2` / `kokoro-int8-en-v0_19.tar.bz2`（bzip2，客户端不可直发，见 CLAUDE.md §7.20/7.21 与研究笔记 §1 客户端硬约束）。候选：

1. 客户端直用 `.tar.bz2` —— 排除（bzip2 纯 Dart 解码过慢，319 MB 模型不可接受）。
2. 复用现有 EchoLoop CDN gzip —— 排除（本票目标即解除该依赖）。
3. 采用第三方 HF 平铺仓库（`abastian` fp32 + `RuiSumida` int8）并另补 espeak —— 非权威、不完整、未核实长期可用性，需决策。
4. 将官方 `.tar.bz2` 重打包为无 macOS 元数据 gzip 后，发布到固定公开位置（如本仓库 GitHub Releases 独立 tag），再落 SHA 常量（研究笔记“先发布产物再写摘要常量”）—— 满足去 CDN 且客户端可消费，但属发布工程与产品决策。

> 决策记录：研究笔记假设 HF 平铺可用，实际不成立（官方 HF 仓库为空），故上报决策后选定候选 4（重打包 gzip + 固定公开位置），未擅自落地未核实 URL 或放宽摘要校验。

## 9. Piper 逐音色核验（issue #22）

> 核验日期：2026-11-10。覆盖研究笔记第 7 节清单 2–4、6–8、10（Piper 职责）。
> 核验方式：9 个音色官方 bz2 与现有 CDN 归档均独立下载、解包后**逐文件**计算 SHA-256 与字节数比对；HF 逐音色仓库经 `huggingface.co/api` 与 `/resolve` 实测（上游与 hf-mirror 双源）；逐音色许可取 rhasspy/piper-voices 的 MODEL_CARD 与指向的数据集许可原文。

### 9.1 结论速览

- 9 个音色官方 `vits-piper-<id>-medium.tar.bz2` 解包内容与现有 CDN `vits-piper-<id>-medium.tar.gz` **逐文件一致**（每个音色 359/359 文件一致，含 `espeak-ng-data/` 355 文件、onnx、onnx.json、tokens.txt、MODEL_CARD）。
- 9 个 `csukuangfj/vits-piper-<id>-medium` HF 仓库全部存在且含 onnx + tokens.txt + espeak-ng-data（355 文件）。但 **ryan/joe/hfc_female 三个 HF onnx 是旧版**（2023-11-29 导出，63201425 字节），与当前 GitHub bz2（2025-12-02 重导出，63149198 字节）及现有 CDN 归档不一致；其余 4 个可下载音色 HF onnx 与现有归档逐字节一致。
- 分发路线据此定为**混合**：amy/kristin/cori/alba 走 HF resolve（含 hf-mirror 镜像收益）；ryan/joe/hfc_female 将当前官方 bz2 重打包 gzip 后上传 loop-back-models `tts-models` tag（保持与现有安装逐字节一致）。
- **lessac/alan 许可不允许再分发**：仅保留目录身份（旧安装继续识别与使用），不建公开资源 spec、不提供下载；英音默认音色从 alan 改为 cori（CC BY 4.0）。

### 9.2 逐音色身份与分发路线

| 音色 id | HF 仓库 commit | HF onnx 与现有归档 | 分发路线 |
| --- | --- | --- | --- |
| en_US-amy-medium | `79936839cc9409b1a752a45c629fe21639e1c1b2` | 一致 | HF resolve |
| en_US-lessac-medium | `83f7470750b36549037551ef7007fa3b4b8697e0` | （不再分发） | 不可再分发 |
| en_US-ryan-medium | `2784cf0f7510312ed567a5d227bcbec28dcd661e` | **不一致（旧版）** | 重打包上传 |
| en_US-joe-medium | `cda0697165d154bb152754dcdf4ea4ad13650e37` | **不一致（旧版）** | 重打包上传 |
| en_US-kristin-medium | `6fdc68249ba2b1b41c1c42ec74341d1599e2c96e` | 一致 | HF resolve |
| en_US-hfc_female-medium | `127829225a73a7f87cb0f07be5aef40895b87abd` | **不一致（旧版）** | 重打包上传 |
| en_GB-alan-medium | `a449faf03a5e8e2eed012793ce95441d0738b605` | （不再分发） | 不可再分发 |
| en_GB-cori-medium | `e304c95c578725ba9cab0cff451c4e5d9aaf889e` | 一致 | HF resolve |
| en_GB-alba-medium | `7e469a54c7a4f5bd191cae788e197266e2c9c5ac` | 一致 | HF resolve |

版本差异证据：ryan/joe/hfc_female 的 HF 仓库 lastModified 为 2023-11-29（onnx 63201425 字节），而 GitHub `tts-models` 对应 bz2 资产 created/updated 为 2025-12-02（onnx 63149198 字节）；现有 CDN 归档跟随新 bz2。tokens.txt 两者一致，仅 onnx 字节不同。

### 9.3 逐音色许可（以 piper-voices MODEL_CARD / 数据集许可为准）

| 音色 id | 许可 | 再分发 | 商用 |
| --- | --- | --- | --- |
| en_US-amy-medium | CC BY-SA 4.0（mimic3-voices） | ✅ | ✅ |
| en_US-lessac-medium | Blizzard 2013 Research Licence（Lessac） | ❌（第 7 条禁止 distribute） | ❌ 仅研究 |
| en_US-ryan-medium | CC BY-NC-SA 4.0（RyanSpeech） | ✅（SA） | ❌ NC |
| en_US-joe-medium | CC0（OHF-Voice） | ✅ | ✅ |
| en_US-kristin-medium | public domain（LibriVox） | ✅ | ✅ |
| en_US-hfc_female-medium | CC BY-NC-SA 4.0（Hi-Fi Captain） | ✅（SA） | ❌ NC |
| en_GB-alan-medium | All Rights Reserved（mimic3 apope_low；finetuned from lessac） | ❌ | ❌ |
| en_GB-cori-medium | CC BY 4.0（Hi-Fi Multi-Speaker, NVIDIA） | ✅ | ✅ |
| en_GB-alba-medium | CC BY 4.0 | ✅ | ✅ |

> hfc_female「特殊许可」核实结论：完整条款为 CC BY-NC-SA 4.0——允许再分发（SA），但**禁止商用**；不是「禁止再分发」。应用免费且不商用，提供该音色非商用使用符合许可。ryan 同为此许可。
> lessac：Blizzard 2013 Lessac「Research Licence Agreement」第 7 条明确「not to lend, hire, sell, distribute or otherwise part with the Materials」；alan：mimic3 apope_low LICENSE 为「All Rights Reserved」且训练注明 finetuned from lessac——两个音色**不允许再分发**，按任务处置为「目录保留、不提供下载」。
> sherpa-onnx 的 ONNX 转换/打包许可为 Apache-2.0，与上述逐音色权重许可分列。

### 9.4 espeak-ng-data 复用结论

- 9 个 Piper CDN 归档（及官方 bz2）内嵌的 `espeak-ng-data/`（355 文件）与 #21 共享树（loop-back-models `espeak-ng-data.tar.gz`）**逐字节一致**（抽查 amy/cori/hfc_female/alan 均 355/355 一致）。
- 结论：Piper 与 Kokoro 复用同一份共享 espeak 资源；模型目录内该目录缺失或损坏时只补该依赖，不重下模型本体（D12）。

### 9.5 重打包资产（ryan/joe/hfc_female）

官方 bz2 → 无 macOS 元数据 gzip（源为 Linux CI 打包、无 PAX/xattr，重打包直接 gzip 同一 tar 流）。先上传 loop-back-models `tts-models` tag（`gh release upload`，未新建 tag），再定稿整包 SHA；匿名下载已验证 200 且 SHA 一致。

| 资产 | 字节数 | 整包 SHA-256 |
| --- | --- | --- |
| `vits-piper-en_US-ryan-medium.tar.gz` | 67370820 | `0cc1c5241f1651b5f893d3259dcd6a9c88acaeb33a59563a0ca1c113ef32c11e` |
| `vits-piper-en_US-joe-medium.tar.gz` | 67329430 | `b8c9581a93b02c67066aad978b6eee56e247c692f82572da00e7b998a13ce38f` |
| `vits-piper-en_US-hfc_female-medium.tar.gz` | 67359748 | `f4dd17d8d1e392df7691a6acb4402e93cb284b935e1cd1e9b86bf108707be784` |

### 9.6 HF 逐文件摘要（amy/kristin/cori/alba）

上游与 hf-mirror 双源独立下载，逐文件内容 SHA-256 与字节数一致；与官方 bz2/现有 CDN 归档逐文件一致。

| 音色 id | onnx SHA-256（字节数） | tokens.txt SHA-256（字节数） |
| --- | --- | --- |
| en_US-amy-medium | `fbaa8e36d8f26fe6f3ebb65cab461e629d8b37a5b7c5fb78fb64317db73e1c25`（63201425） | `87c8ef66eae5473ed0cc0366b3964c736ca6c5f676c979522ea31234e47430b9`（921） |
| en_US-kristin-medium | `f9a5c375c70ddc33ccdb3969c76a4d7cc5255ac08119a312b0034a1d07041be6`（63531507） | `ef3a7e4a8d1af0c9d4dc45aaae1a6242ebe24a7ed6f3d025a49eb29682784c6d`（940） |
| en_GB-cori-medium | `8b0d3cdd77f2878e0aa2048103eabb4d01b334783f99629f042bcf703aeba487`（63531507） | `ef3a7e4a8d1af0c9d4dc45aaae1a6242ebe24a7ed6f3d025a49eb29682784c6d`（940） |
| en_GB-alba-medium | `c904d007a8047ab13628b021351b983d0a2627c0d7a81c64a6fe9ad661adb1cf`（63201430） | `87c8ef66eae5473ed0cc0366b3964c736ca6c5f676c979522ea31234e47430b9`（921） |

> 注：ryan/joe/hfc_female 的 HF onnx 为旧版（63201425），未采用其摘要；其当前 bz2 onnx 字节见重打包资产（§9.5）。
