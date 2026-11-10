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
