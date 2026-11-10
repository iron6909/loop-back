# 词典与发音库去 EchoLoop 化：固定公开源分发与来源展示

> 规格日期：2026-11-10。依据已确认的 D1–D13 决策与 Q14 追加确认整理，业务实现尚未开始。
> 发布状态：已发布至 [GitHub issue #26](https://github.com/iron6909/loop-back/issues/26)，已应用 `ready-for-agent`。

## Problem Statement

英语学习者查词依赖离线词典提供音标、释义、柯林斯星级与考试标签，发音朗读优先使用预录的单词发音。当前词典（zh-CN / zh-TW）与发音库的下载仍依赖 EchoLoop 的资源 CDN——这是正常学习流程对该域名的最后依赖。原资源服务一旦不可用，新设备的词典与发音库安装就受影响。

发音库下载还在启动后自动进行、失败静默：用户只听到发音回退为合成音，不知道资源下载失败，也没有重试入口。用户也无法在设置里看到离线资源的来源与许可。

改造还必须保护已有安装与学习数据：已下载的词典与发音库不能因换下载来源而失效或强制重下，备份恢复行为不能改变，查词与发音朗读的既有体验必须保持。

## Solution

三个资源归档（词典 zh-CN、词典 zh-TW、发音库）保持内容字节不变，原样重托管到一个固定的 Hugging Face 公开源（固定 revision + 整包 SHA-256），并提供 hf-mirror 镜像供不可达主站的用户手动切换。镜像与主站使用同一份资源身份与摘要。

词典设置页新增「离线资源」区：逐语言展示数据来源与许可（ECDICT MIT + 托管仓库）、下载状态与重试；发音库增加状态行与失败重试入口，不再静默无感。发音库来源无法核实，如实只标注托管仓库、不虚构第三方许可。

下载来源切换复用语音识别已落地的同一份偏好与开关，两个设置入口读写同一份状态。完成后删除共享 CDN 配置与路由，正常流程不再引用任何 EchoLoop 域名，仅保留官网链接。首期面向 Android 真机验收，保持 iOS/macOS 的可编译性与既有功能。

## User Stories

1. As a new user, I want the offline dictionary and pronunciation library to download from a fixed public source, so that installing them does not depend on EchoLoop's resource service.
2. As a user with restricted network access, I want to switch the download source between the public upstream and a clearly identified mirror, so that I can use a reachable source.
3. As a learner looking up a word before the dictionary is downloaded, I want the lookup panel to keep showing download progress and retry, so that failures do not silently leave me without definitions.
4. As a learner, I want to see the data source and license of each offline dictionary in settings, so that I know where the lookup data comes from.
5. As a learner, I want to see the pronunciation library's source and download status in settings, so that its failures are visible and retryable instead of silent.
6. As a learner, I want word playback to keep preferring recorded pronunciation and falling back to speech synthesis, so that my listening experience does not change.
7. As a new user, I want the pronunciation library to keep downloading automatically at startup, so that word pronunciation works without extra setup, only the source changes.
8. As a user downloading a resource, I want progress, cancellation, and actionable errors, so that I can control a large download.
9. As a user downloading a resource, I want corrupted or incomplete archives rejected while a working installation is retained, so that a failed download does not break lookup or playback.
10. As a returning user, I want my existing valid dictionary and pronunciation installations to remain usable after upgrading, so that I do not have to download the same resources again.
11. As a user with legacy dictionary data, I want migrated old dictionary installations to keep working, so that historical local data is not lost.
12. As a user with a damaged installation, I want it to return to the not-installed state with a repair entry, so that I can fix it by downloading again.
13. As a user on a flaky network, I want partially downloaded archives to be resumed safely, so that bandwidth is not wasted on repeated full downloads.
14. As a user canceling a download, I want no half-installed resource to be published, so that cancellation keeps the previous state.
15. As a user creating a backup, I want the dictionary to stay included and the pronunciation library to stay excluded, so that backup behavior does not change.
16. As a user restoring a backup, I want the restored dictionary to remain valid, so that restoring does not force a re-download.
17. As a user switching the download source, I want the same resource identity and checksums to apply to both sources, so that switching does not change what is trusted.
18. As a user on the Chinese mainland, I want the mirror to serve the same verified archives as the upstream, so that I can install resources when the upstream is unreachable.
19. As a learner, I want dictionary and pronunciation downloads to share the existing download-source switch with speech models, so that I manage one source setting instead of several.
20. As a settings user, I want the source switch in dictionary settings to control the same preference as the speech recognition settings switch, so that the two screens never disagree.
21. As a learner, I want normal lookup and playback flows to work without any EchoLoop domain, so that the app remains functional if the original service disappears.
22. As a returning user with either dictionary language variant, I want both zh-CN and zh-TW to remain available as before, so that changing app language does not change my dictionary experience.
23. As a learner, I want the pronunciation library labeled with only its hosting repository and no invented third-party license, so that the app does not misattribute audio whose source cannot be verified.
24. As a learner using the dictionary panel while a dictionary is downloading, I want lookup to fall back to other enabled dictionary sources, so that studying is not blocked.
25. As a learner whose pronunciation download failed, I want word playback to fall back to speech synthesis without interruption, so that a failed download does not break pronunciation.
26. As an Android learner, I want public-source downloads, mirror switching, offline lookup, playback, and backup restore verified on a real device, so that desktop tests are not mistaken for proof of mobile reliability.
27. As an iOS or macOS learner, I want the existing dictionary and pronunciation paths to remain functional, so that this Android-focused change does not remove supported behavior.

## Implementation Decisions

1. **资源身份与内容不变。** 三个归档原样重托管，内容字节不变；resourceId、安装目录与统一安装清单不变。旧的有效安装、旧 `dict.db` 迁移产物与备份恢复的词典继续识别，不强制重下；实现核验若发现公开源内容与现有归档不一致，如实记录版本变化并另行决策，不能伪称只改下载地址。

2. **公开资源目录。** 词典与发音库的目录记录固定公开仓库、revision、整包 SHA-256、字节数与来源标注。复用语音识别已建立的公开资源描述类型（下载来源枚举、固定身份描述），不另起一套；与语音识别目录保持同一实现先例。实施第一步先完成独立下载核对（上游与镜像双源整包 SHA 与解包逐文件比对），全部通过前不把预期仓库名或 revision 写成代码常量。

3. **下载来源偏好单一来源。** 复用已落地的下载来源偏好（同一存储键与枚举：上游默认、镜像手动切换）。词典与发音库下载时读取该偏好决定实际域名；两个来源使用同一资源身份与摘要。语音识别设置页与词典设置页的开关读写同一份状态；不做按地区自动默认。

4. **分发与安装语义。** 管理器下载地址构造从共享 CDN 路由改为公开源解析（主源或镜像），保留整包 SHA 校验、staging 解包校验、原子发布、失败回滚、`.part` 续传与取消；损坏或截断安装回到未安装态并给出修复入口。跨来源续传无法证明资源相同则重启下载。

5. **界面与来源展示。** 词典设置页新增「离线资源」区：逐语言展示来源与许可（ECDICT MIT + 托管仓库）、下载状态、进度与重试；发音库单行展示来源（仅托管仓库）、状态与重试；下载来源切换入口与语音识别设置页同源。查词面板内既有的词典下载/重试入口保持不变。

6. **发音库行为保持不变。** 启动后缺失即自动下载、单词朗读优先离线发音且失败回退语音合成的既有行为不变；仅新增设置页可见的失败状态与重试入口，不再静默无感。

7. **域名隔离收口。** 删除共享 CDN 常量与运行时 CDN 路由（词典与发音库是最后使用方）；官网 API 地址与社区邀请等外链保持不变。隔离 EchoLoop 域名后新安装、查词与发音朗读必须可用，正常流程不再引用该域名。

8. **来源与许可如实标注。** 词典标注数据来源 ECDICT（MIT 许可）与托管仓库；发音包来源无法核实，只标注托管仓库、不标注第三方来源与许可，处置记录见 ADR-0002。zh-TW 与 zh-CN 内容逐字节相同是已知事实，本次保留两个变体原样分发。

9. **备份与恢复边界不变。** 词典继续随备份（`resources/dictionary/`），发音库继续不随备份；恢复不触发下载，恢复出的词典按同一 resourceId 继续有效。

10. **验收边界。** 首期英语、Android 真机优先（公开源下载、镜像切换、断网降级、备份恢复往返、域名隔离证据）；Windows 全量测试；Apple 平台保持可编译与既有功能，正式宣称前补 macOS 宿主实机证据。

## Testing Decisions

1. **以外部行为为标准。** 好的测试从用户可触发的公开操作出发（下载、切换来源、重试、取消、查词、朗读、备份恢复），观察任务状态、实际请求与持久化内容，不断言私有方法调用顺序、组件结构、字号、颜色或间距。

2. **最高既有业务入口优先。** 主测试边界位于词典下载管理器与发音库管理器的公开入口，以及词典设置页的 widget 测试；沿用现有注入点，不为测试引入新的通用业务门面，不对同一行为在每一层重复写镜像测试。

3. **复用副作用注入。** 使用现有 Dio/URL 注入与真实临时目录、内存数据库组合真实安装流程；只替换网络等不可控边界。现有词典下载与发音库管理器测试是主要先例。

4. **资源安装专项。** 覆盖固定资源身份、错误摘要、中断、取消、镜像身份一致、原子发布失败回滚、旧安装与旧迁移产物识别、损坏修复、两个词典变体各自独立安装；不通过模拟内部校验函数来证明文件完整性。

5. **下载来源与偏好。** 验证两个来源解析出同一资源身份、偏好读写一致、语音识别设置与词典设置的开关同源互见、默认上游、切镜像后下载使用镜像域名。

6. **域名隔离回归。** 路由与配置测试更新为无 CDN 路由；编译产物与正常流程不再出现 EchoLoop CDN 域名，官网链接保持不变。

7. **备份恢复真实往返。** 使用真实内存数据库与备份导入流程，验证词典随备份恢复且继续有效、发音库不随备份、恢复不触发下载。

8. **界面与平台。** 词典设置页 widget 测试覆盖来源/许可展示、发音库失败状态与重试、下载来源切换；Android 真机端到端验证公开源下载、镜像切换、断网查词与发音降级、备份恢复；保持 iOS/macOS 编译与原有行为检查。普通自动化测试不发真实付费请求；真实供应商与设备表现以实机记录为准。

## Out of Scope

- 词典数据重建或升级：从最新 ECDICT 重编译、zh-TW 繁体化、发音音频换源或补英音、条目筛选规则变更。
- 在线 TTS、词典引擎更换，以及网页词典、AI 词典的改造。
- 新资源类型、手动导入资源文件、任意下载 URL 或通用插件框架。
- 按地区自动选择下载源（已确认手动切换）。
- 上一轮审计发现的无关小清理（死 ARB 文案、去品牌文案、废弃脚本），单独立项处理。
- Windows、Linux、Web 新增支持；未经实机验证即宣称 Apple 平台验收完成。

## Further Notes

- 产品决策来自两轮已确认的 D1–D13 与 Q14 追加确认，无新增产品访谈。领域术语使用离线词典、发音库、词典源、语音合成。
- 制品解剖于 2026-11-10 实测：三个归档整包 SHA 与代码目录一致；词典 zh-CN / zh-TW 解包后 sqlite 逐字节相同（248,891 条，ECDICT 筛选子集）；发音包 10,629 条全美音 Ogg Opus，特征文件名公开检索无任何数据集指纹。完整数值与核对清单见 [research-dict-public-sources.md](./research-dict-public-sources.md)。
- 操作者前置行动：新建 HF 数据集仓库并原样上传三个归档、固定 revision、撰写来源说明；实施第一步按研究笔记第 3 节核对清单独立下载核对。
- 发音包来源无法核实的再分发与标注策略见 [ADR-0002](../../adr/0002-pronunciation-pack-unverified-provenance.md)；本地决策材料见 [方案](./plan.md) 与 [术语表](../../../GLOSSARY.md)。
- 票据状态以 GitHub issue 为准；本地保留方案、研究笔记与领域文档。代码实施尚未开始。
