# 词典与发音库公开源研究笔记

> 2026-11-10。CDN 可访问，三个归档已实际下载解剖；网页检索经公开搜索完成，页面级事实待实施独立下载核对。

## 1. 现有 CDN 制品解剖（已核实）

下载基址 `https://cdn.echo-loop.top`，三个归档的整包 SHA-256 与代码内目录值逐一匹配：

| 归档 | 整包字节 | 整包 SHA-256（与 catalog 一致） | 解包内容 |
| --- | --- | --- | --- |
| `dictionary/en_zh-CN/dict_en_zh-CN-v1.sqlite.zip` | 12,552,930 | `2acfc22aae4658b707973c508e1356d4c8ce4bc07c502c6d2c3030a95bc5f5e9` | `dict_en_zh-CN-v1.sqlite` |
| `dictionary/en_zh-TW/dict_en_zh-TW-v1.sqlite.zip` | 12,552,893 | `dee7bc7d6ec43f88371d17a6a2595d277172a8897d70ff9a280a5ef8142d4cac` | `dict_en_zh-TW-v1.sqlite` |
| `dictionary/pronunciation-v2.zip` | 41,379,389 | `db1bf8c8ec953f48ed05e22f8254cd8385f3c26f0acb630f73aedf14bbb6a1ca` | `pronunciation.sqlite` + `audio/*.opus` ×10,629 |

### 1.1 词典 sqlite

- 表：`words(word TEXT PRIMARY KEY, phonetic TEXT NOT NULL, translation TEXT, collins INTEGER DEFAULT 0, tag TEXT)`。
- 条目数：zh-CN 与 zh-TW 均为 248,891。
- 解包后 sqlite 的 SHA-256 完全相同：`2d17d4d3f83aae4b57c143f53c7f8e07a5ac3efbc1ed7e5486e26126060f4898`（zh-TW 与 zh-CN 内容逐字节一致，仅 zip 压缩层不同）。
- 样本（`a`、`aaaa`、`aaad` 等）与 ECDICT 字段语义一致：音标、中文释义（含词性前缀、多义项换行）、柯林斯星级、空格分隔标签（`zk gk` 等）。

### 1.2 发音包

- 表：`pronunciation_audio(id, word COLLATE NOCASE, locale CHECK(locale IN ('us','uk')), audio_filename, "order")`，`UNIQUE(word, locale, audio_filename)`。
- 条目数：10,629，全部 `locale='us'`（允许 uk 但实际无英音条目）。
- 音频：Ogg Opus（`OggS` 头），每条约 1.2–11 KB（1–2 秒），共 38,232,577 字节。
- 命名：`word_us.opus`；词性消歧 `_n`/`_v`/`_adj`/`_interj`（`subject_us_n.opus`、`tear_us_v.opus`）；连字符与缩写（`a-bomb_us.opus`、`they'll_us.opus`）。

## 2. 来源核查

### 2.1 词典数据

- skywind3000/ECDICT（MIT 许可）：字段 word/phonetic/definition/translation/pos/collins/oxford/tag/bnc/frq/exchange/detail/audio；官方提供 CSV，SQLite 由 `stardict.py` 转换（表 `stardict`，字段同上）。
- 当前词典只保留 word/phonetic/translation/collins/tag 五个字段，条目数 24.9 万，小于 ECDICT 全量（约 77 万），是筛选后的子集；筛选规则与处理脚本未知，因此本次**不重建**（D1、D8）。
- 结论：词典数据来源标注为 ECDICT（MIT），托管仓库为自建 HF 仓库。

### 2.2 发音音频

- 用特征文件名（`zygodactylous_us.opus`、`subject_us_n.opus`、`yeah_us_interj.opus`）公开检索，无任何已知数据集指纹；不是 Forvo（CC BY-NC-SA）、MLCommons（关键词语料）、Appen/LDC（付费）等公开音频库的原样拷贝。
- 来源无法核实。按 D10：原样重托管，界面只标注托管仓库、不标注第三方来源与许可；风险与处置记录于 ADR-0002。

### 2.3 托管先例与镜像

- `iamzhangship/fluency-ecdict-offline`（HF dataset）：以固定版本、整包 SHA-256、来源与许可文档分发 ECDICT SQLite 包，月下载约 915 次；与本项目 ASR/TTS 公开源规则同构。
- hf-mirror.com 覆盖 HF dataset 下载；镜像切换沿用 ASR 已落地的同一资源身份 + 明确标识模式。
- 本次由操作者在 HF 新建数据集仓库，原样上传三个归档并固定 revision（前置行动）。

## 3. 独立下载核对记录（2026-11-10 已完成）

- 公开源仓库：`banko3/loop-back`（HF dataset，public、非 gated）；固定 revision `3b3a5bef53a1c2c86f72117a8ce149554122baac`；卡片标注 MIT（词典数据）+ 发音包仅标注托管仓库（同 ADR-0002）。
- 双源下载核对：huggingface.co 与 hf-mirror.com 在固定 revision 各下载三个归档，整包 SHA-256 与字节数全部与第 1 节一致。
- 与 CDN 原件比对：双源下载物与现有 CDN 归档逐字节一致（归档级一致强于解包比对，解包内容必然一致）。
- 结论：三个资源按「同一身份、不重下」落地公开源成立；实施可直接把仓库名与 revision 写成代码常量。
