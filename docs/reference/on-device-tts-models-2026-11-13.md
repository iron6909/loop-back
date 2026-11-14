# 端侧（手机）本地语音合成模型调研

> 快照时间：2026-11-13。许可与体积数据以各上游 `LICENSE` / `MODEL_CARD` / 模型卡为准，
> 选型落地前必须按来源逐项复核；本文件只记录调研结论与出处。

## 1. 结论摘要

- 手机 App 里真正使用量最大的本地 TTS 不是 IndexTTS，而是**系统引擎 + Piper 系**。
- IndexTTS 系列（1 / 1.5 / 2 / 2.5）是 **PC / GPU 端**的开源明星，无法进入手机运行时；
  其权重许可是 bilibili 自有协议，不是 Apache-2.0（社区文章常误标）。
- 音色能否开源下载必须分两类看：Kokoro / Kitten / Pocket TTS / Supertonic / ZipVoice
  有明确统一许可；Piper 是**逐音色各自许可**；MMS-TTS / ChatTTS / F5-TTS 权重为非商用。

## 2. 手机端本地 TTS 的四层格局

| 层 | 代表 | 说明 |
| --- | --- | --- |
| 系统引擎（闭源，装机量最大） | Android 语音服务（Google）、三星 TTS；iOS `AVSpeechSynthesizer` + 可下载神经音色 | App 的默认朗读基本都走这里，量级是整机预装，但模型不可随应用打包 |
| 商业嵌入式 SDK | Cerence / Nuance Vocalizer、Acapela、ReadSpeaker、Picovoice Orca（8 MB） | 车载、无障碍、教育类应用常买这类授权 |
| 开源嵌入式（事实标准） | **sherpa-onnx**（Apache-2.0）承载七族模型：VITS（含 Piper、MeloTTS）、Matcha、Kokoro、Kitten、ZipVoice、Pocket、Supertonic | 端侧开源 TTS 基本都靠它。生态案例：Home Assistant、NVDA、MediaTek BreezeApp、中国联通 / 中国人寿安卓 App（KWS / ASR）。纯 TTS 应用体量很小，例如 VoxSherpa 约 1.3 万安装 |
| 开源但只跑 PC / GPU | **IndexTTS-2 / 2.5**、CosyVoice2、GPT-SoVITS、F5-TTS、Fish / OpenAudio、ChatTTS、Spark-TTS、MegaTTS3 | 中文圈热度最高的一档，属于「本地部署」，不是「手机端部署」 |

端侧开源模型的装机量排序：**Piper（44 种语言、上千音色）> Kokoro（82M，质量体积比最好，近两年增长最快）> 其余**。

## 3. IndexTTS 的准确定位

- **不能上手机。** IndexTTS-2 采用「GPT 式自回归 + 流匹配 + BigVGAN」架构，FP16 实测约需
  8 GB 显存，模型仓库几十 GB；社区主流用法是 RTX 3060 及以上。IndexTTS-2.5（2026-08-10 发布）
  新增中/英/日/西/阿、情感与语速控制、vLLM 部署，仍是服务器路线。
- **许可不是 Apache-2.0。** `index-tts/index-tts` 仓库 License 字段为 `Other`，走 bilibili 自有
  模型许可：禁止用其改进其他模型（非商用除外）、衍生作品需带指定声明、高危场景（医疗、征信、
  生物特征监控等）禁用、PRC 法域与上海仲裁。设计商用前必须读仓库内 LICENSE。
- **没有可再分发的官方音色库。** 它是 zero-shot 克隆：提供一段参考音频即可复刻音色。
  官方在线版展示的「音色库」属于其 SaaS 资产，不开源。
- 对离线 App 的正确用法是**离线预生成固定音色素材**，而不是运行时引擎；此时版权风险落在
 参考音频本身（不得使用受版权保护或未经授权的他人录音）。

## 4. 权重与音色可再分发性

| 模型 | 体积 | 音色 | 权重许可 | 可否随 App 分发 |
| --- | --- | --- | --- | --- |
| Kokoro v1.0 | 82M / 约 340 MB（fp32） | 54 个（8 语言）；v0.19 为 11 个英文音色 | Apache-2.0，训练数据全部为许可 / 无版权音频 | 可以，最干净 |
| Kitten TTS | nano 15M（< 25 MB）；Kitten-TTS 2 为 1.7B 1-bit | v0.8 八个音色；Kitten-TTS 2 有 115 个内置音色 + 5–30 s 克隆 | Apache-2.0 | 可以，适合低配省电档 |
| Pocket TTS（Kyutai） | 100M | 26+ 预置音色 + 克隆（英 / 法 / 德 / 葡 / 意 / 西） | 权重 CC-BY-4.0（需署名），代码 MIT | 可以，但 `cosette` / `jean` 音色为 CC-BY-NC，商用前必须剔除 |
| Supertonic 3 | 99M，ONNX Runtime，纯 CPU | 预设 voice style（M1 / F1 等）+ Voice Builder 自定义 | 权重 **OpenRAIL-M**（可商用，带使用限制与署名要求） | 可以但要读条款；上游仓库已归档，存在维护风险 |
| ZipVoice | 123M | 无预置音色，零样本克隆（中英） | Apache-2.0 | 许可最松，但手机端只能跑 CPU，且必须自带参考音频与参考文本 |
| Piper | 20–60 MB / 音色 | 1000+ 音色，44 语言 | **逐音色各自许可**（每音色 `MODEL_CARD`），引擎本体 GPL-3.0 | 只能挑选可再分发的音色 |
| MMS-TTS（Meta） | 约 145 MB / 语言 | 1100+ 语言，每语言 1 音色 | CC-BY-NC-4.0 | 不可商用 |
| ChatTTS / F5-TTS | 0.7B / 0.3B | 克隆 | 权重 CC-BY-NC | 不可商用 |
| IndexTTS-1 / 1.5 / 2 / 2.5 | GB 级 | 克隆，无官方音色库 | bilibili 自有许可 | 体积与算力均不合适 |

## 5. 与当前实现的对照

当前实现（`pubspec.yaml` → `sherpa_onnx: ^1.13.4`）：

- `lib/services/tts/kokoro_voices.dart`：Kokoro `kokoro-en-v0_19` 的 11 个英文发音人，美音 6 + 英音 4
  （另有默认 sid 0）。
- `lib/services/tts/piper_model_catalog.dart`：Piper 7 个音色，逐音色许可字符串在
  `PiperVoice` 上（文件第 110 行附近），lessac / alan 因许可禁止再分发已移除。
- 许可过滤应继续收敛在 model catalog 层，新增引擎沿用同一约定，不在 UI 层判断。

## 6. 落地建议（按改造成本排序）

1. **Kokoro 升级到 `kokoro-multi-lang-v1_0`**：sherpa-onnx 已支持，音色从 11 个扩到 53 个以上，
   许可仍为 Apache-2.0，商业风险最低。
2. **新增 Kitten nano 档**：< 25 MB、Apache-2.0，作为低端机 / 省电选项，比 Piper 更小。
3. **升级 sherpa_onnx 到 2.0.x 后接 Supertonic 3 与 Pocket TTS**：这两族的 Dart 配置在 2.0.x 才有，
   官方提供对应 Flutter demo APK，可先做真机 RTF 对比再决定是否内置。
4. **IndexTTS 不进运行时**：若确实需要更自然的示范音，可用其在 PC 上离线批量生成固定句子音频。

## 7. 风险与未验证项

- Supertonic 上游仓库（`supertone-oss-archive/supertonic`）已归档，官方声明不再维护。
- Pocket TTS 音色许可混杂：权重 CC-BY-4.0 需署名，克隆权重在 HF 上是 gated，且部分预置音色为
  CC-BY-NC；`kyutai-labs/pocket-tts` #403 仍在讨论商用与 VCTK 派生音色的条款。
- IndexTTS 许可在中文社区被普遍误标为 Apache-2.0，任何引用都应以仓库 LICENSE 为准。
- 未做真机实测：本轮未在 2.0.x 上跑官方 Flutter demo，因此没有本机机型上的 RTF / 内存数据。
- 安装量只能取到个别可查案例（VoxSherpa 约 1.3 万），其余按生态依赖度判断，不是精确统计。

## 8. 来源

- `k2-fsa/sherpa-onnx` README、`sherpa-onnx/csrc/sherpa-onnx-offline-tts.cc`（七族模型参数）、
  TTS Model Zoo 文档、pub.dev `sherpa_onnx` 2.0.0 示例列表
- `index-tts/index-tts` README 与 License 字段（IndexTTS-2.5，2026-08-10）
- `hexgrad/Kokoro-82M` 模型卡（v1.0 / v0.19 语言与音色数、训练数据来源）
- `OHF-Voice/piper1-gpl` `docs/VOICES.md`、`rhasspy/piper-voices` `voices.json`
- `KittenML/KittenTTS`、`KittenML/kitten-tts-nano-0.1` / `0.2` 模型卡
- `kyutai-labs/pocket-tts`、`kyutai/pocket-tts` 模型卡、issue #403（音色许可讨论）
- `supertone-oss-archive/supertonic`、`supertone-oss-archive/supertonic-3`（OpenRAIL-M）
- `k2-fsa/ZipVoice`
- Picovoice《On-device TTS Comparison》2026 基准（模型体积与峰值内存横向对比）
