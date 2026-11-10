# 语音合成去 EchoLoop 化：公开本地模型与真实身份展示

> 规格日期：2026-11-10。依据已确认的 D1–D13 决策整理，业务实现尚未开始。
> 发布状态：已发布至 [GitHub issue #20](https://github.com/iron6909/loop-back/issues/20)，已应用 `ready-for-agent`；实施工单 [#21](https://github.com/iron6909/loop-back/issues/21)–[#25](https://github.com/iron6909/loop-back/issues/25) 已作为子 issue 挂接。

## Problem Statement

英语学习者需要稳定地把单词与例句朗读出来。当前两个本地合成模型以 Echo Loop AI 的 Advanced、Balanced 名称展示，实际已经是开源的 Kokoro 82M 与 Piper VITS 模型，但模型下载仍依赖 EchoLoop 的资源服务，界面也没有模型出处与许可信息。用户无法判断自己设备上运行的真实技术；原服务不可用时，新设备的语音合成模型安装也会受影响。

改造还必须保护已有安装、偏好与合成缓存：升级不能强迫用户重新下载几十到几百 MB 的模型，不能因为改名丢弃已经合成好的音频缓存，也不能让失败的下载损坏正在使用的模型。界面上的品牌文案必须还原为真实模型名，同时保持发音朗读与试听等既有功能不变。

## Solution

继续使用现有 Kokoro 与 Piper 模型和 sherpa-onnx 引擎，以真实模型名称、公开出处和许可信息呈现；将 TTS 模型资源迁往固定版本的公开来源，并提供可手动切换的镜像。已安装且有效的模型继续使用，合成缓存与全部偏好保留。

界面中 Kokoro 的两个精度打包以 Full precision (fp32) 与 Quantized (int8) 如实展示；Piper 按音色展示各自来源与许可。删除与管理入口的文案改为真实名称，删除保护等既有交互不变。首期面向英语与 Android 真机验收，保持 iOS/macOS 的可编译性和既有功能。

## User Stories

1. As an English learner, I want to see the real Kokoro and Piper model names and their public origins, so that I understand which technology synthesizes speech on my device.
2. As an English learner, I want the two Kokoro precision variants labeled as full precision and quantized, so that the displayed choice reflects what actually differs between them.
3. As a new user, I want to install speech synthesis models without relying on EchoLoop's resource service, so that the original product's availability does not determine whether pronunciation works.
4. As a user with limited network access, I want to switch between a public model source and a clearly identified mirror, so that I can use a reachable download source.
5. As a user downloading a model, I want progress, cancellation, and actionable errors, so that I can control a large download.
6. As a user downloading a model, I want incomplete or corrupted files to be rejected while a working installation is retained, so that a failed download does not break pronunciation.
7. As a returning user, I want my existing valid Kokoro and Piper installations to remain usable after upgrading, so that I do not have to download the same models again.
8. As a returning user, I want only a missing shared pronunciation-data resource to be downloaded, so that I do not waste bandwidth downloading an already installed model.
9. As an offline learner, I want installed local synthesis to keep working without an online account or network, so that pronunciation remains available offline.
10. As a Piper voice user, I want to see each voice's origin and license, so that I know where each downloaded model comes from.
11. As a user choosing a voice, I want the eleven Kokoro and nine Piper voices to keep their identities and accents after the rename, so that my voice selection still sounds the same.
12. As a user deleting a model, I want the confirmation to name the actual model, so that I understand exactly what I am removing.
13. As a user managing downloads, I want the downloaded-models section to describe models without an unrelated brand name, so that the management screen stays honest.
14. As a returning user, I want my engine, accent, voice, and variant preferences preserved after upgrading, so that upgrading does not unexpectedly change my workflow.
15. As a returning user, I want already synthesized pronunciation audio to remain cached, so that I do not re-synthesize everything after the rename.
16. As a new user, I want the default engine, variant, and voices to remain the same as before the rename, so that the out-of-the-box experience does not change.
17. As a user with a corrupted model installation, I want the app to report it as not installed with a repair path, so that I am not stuck with a broken voice.
18. As a system speech user, I want platform speech to behave exactly as before, so that this change only affects the two downloadable engines.
19. As a user previewing voices in settings, I want voice previews to keep working with models from public sources, so that I can audition a voice before using it.
20. As a learner studying offline or abroad, I want model downloads and synthesis to work with the EchoLoop domain unreachable, so that the original service is not a hidden requirement.
21. As a privacy-conscious user, I want the application to avoid contacting the original service for speech synthesis entirely, so that my device does not depend on it in normal use.
22. As an Android learner, I want model downloads and synthesis verified on a real device, so that desktop tests are not mistaken for proof of mobile reliability.
23. As an iOS or macOS learner, I want the existing application and pronunciation paths to remain functional, so that this Android-focused change does not remove supported behavior.

## Implementation Decisions

1. **本地模型身份与执行方式。** 保留 Kokoro 82M 两个精度打包、9 个 Piper 音色、现有内部 ID 和 sherpa-onnx `OfflineTts` 引擎。展示 Kokoro / Piper、公开出处、许可与资源信息；Kokoro 变体展示 Full precision (fp32) 与 Quantized (int8)。名称变化不触发模型身份、安装目录、偏好或合成缓存重建。

2. **公开资源分发。** 建立 TTS 资源目录记录固定 revision/发布 tag、逐文件 SHA-256、字节数、许可与共享依赖；与 ASR 公开资源目录同构或共用抽象。默认公开上游与手动镜像使用相同资源身份；优先 Hugging Face resolve，镜像明确标识为 hf-mirror.com；GitHub 发布资产只在上游无已核实镜像时使用，选择镜像时仍走上游地址。具体上游仓库与文件布局以外部核查结论为准，实施前独立下载核对目标文件与现有归档的逐文件摘要与字节数。下载器保留临时安装、校验、取消、失败清理及原子发布，只有完整成功后才发布新安装；跨来源续传无法证明身份一致时重启该文件。已安装有效模型与历史归档安装清单继续兼容。官方 HF 形态缺失或为客户端不可消费格式（bzip2）时，允许重打包为无 macOS 元数据 gzip 并发布到固定公开位置（本项目 iron6909/loop-back-models tag tts-models），以逐字节一致核验与整包 SHA 为信任依据。

3. **共享发音数据。** Kokoro 与 Piper 共用的发音数据按共享依赖处理：具有固定公开来源与校验依据，安装校验只缺该依赖时只补它，不重下模型本体。

4. **界面品牌与来源展示。** 引擎单选显示 Kokoro / Piper 与系统语音；删除确认与管理标题改为真实名称文案；设置页展示模型来源与许可，Piper 逐音色展示（同源同许可时可合并展示一行）。保留引擎切换、音色底部弹层、删除保护、试听预热与下载反馈等既有交互。

5. **来源切换。** 语音合成设置页提供公开上游与镜像切换项，作用于全部有镜像的资源；无镜像资源的地址不随切换猜测变化。切换来源不影响已安装模型的可用性。

6. **迁移兼容。** 引擎、音色、变体、口音偏好键与值保持不变；变体 id 与 Piper 音色 id 同时是目录名、缓存键与下载状态 key，必须保持。公开源文件与旧归档逐文件一致时旧安装视为同一身份、不强制重下；不一致则明确记录版本变化并另行决策。损坏/截断安装回到未安装态并给出修复入口。合成缓存键含 voiceId 与 modelTag，模型文件身份不变则缓存继续有效。新装默认保持 Kokoro 引擎、fp32 变体与默认音色（Piper 英音默认为 cori：alan 许可不允许再分发，仅保留目录身份）。

7. **可靠性语义。** 下载继续使用可续传下载器、staging 校验与原子发布；整包 tar.gz 还是逐文件下载由上游实际形态决定，两种形态都逐文件校验后才发布。失败回滚不损坏旧安装，取消清理临时文件。

8. **范围约束。** 只拆 TTS 对共享区域 CDN 的依赖；词典、播客等仍走该路由的资源另行立项。不新增在线 TTS、手动模型导入或任意下载 URL；平台 TTS 不下载模型、不进资源目录；TTS 相关代码注释中的品牌名随本次修正，不扩大到整款应用更名。

## Testing Decisions

1. **以外部行为为标准。** 好的测试从用户可触发的公开操作出发，观察下载请求地址、安装状态、实际合成与失败后的数据保留。不断言无关私有方法调用顺序、组件结构、字号、颜色或间距。

2. **最高既有业务边界优先。** 主测试边界位于模型管理器的公开安装/删除/就绪操作、语音合成设置状态与设置页：从触发下载、切换来源、删除或升级迁移，覆盖到安装发布与合成可用。沿用现有入口，不为测试引入新的通用业务门面。

3. **复用副作用注入。** 使用现有受控下载响应、临时目录解析器与真实安装管线；只替换网络与平台录音等不可控边界。现有 Kokoro/Piper 模型管理器与设置页测试是主要先例。

4. **资源安装专项。** 通过模型管理器的公开安装操作，覆盖固定资源身份、错误摘要、中断、取消、镜像身份、原子替换、旧归档兼容、损坏修复与共享发音数据单独缺失。参考 ASR 模型管理器测试的边界；不通过模拟内部校验函数来证明文件完整性。

5. **迁移与缓存专项。** 验证已装模型在公开源切换后不重下、偏好与合成缓存保留、损坏安装修复、备份恢复行为不变。沿用既有 tts 设置与控制器回归。

6. **界面专项。** 设置页 widget 测试验证引擎名、变体名、逐音色来源/许可、删除与管理文案、来源切换项与试听预热在去品牌后仍然工作；断言界面不再出现 Echo Loop 品牌文案。

7. **设备与平台。** Android 真机验证公开源下载（含镜像切换）、隔离 EchoLoop 域名后的合成与试听、损坏安装修复；iOS/macOS 保持编译与既有功能，原生引擎集成测试在支持的平台 runner 上运行。

8. **测试层次与证据。** 自动化测试不提交模型权重、不发付费请求；公开源摘要与字节数以实施期独立下载为准。实施按改动范围执行检查，整体交付再执行跨模块完整检查，平台阻塞明确记录。本次生成规格不构成任何运行时验收。

## Out of Scope

- 整款应用更名，以及词典、播客等非 TTS 资源的去品牌化或下载体系改造。
- 替换现有 sherpa-onnx 推理引擎，或更换 Kokoro/Piper 之外的模型家族。
- 模型版本升级（新的 Kokoro 版本、新的 Piper 音色）与新增音色。
- 在线 TTS、云端音色或第三方合成服务接入。
- 手动导入模型文件、任意模型资源下载 URL、未经校验的镜像内容。
- 平台 TTS 行为改造；Windows、Linux、Web 新增支持。
- 恢复 EchoLoop 登录、会员与配额门控。
- 将既有 Android 录音 native/VAD 崩溃视为本次已解决；相关稳定性问题继续独立跟踪。

## Further Notes

- 产品决策来自两轮已确认的 D1–D13，无新增产品访谈或范围选择。领域术语使用语音合成、合成引擎、音色与模型变体。
- 本地决策材料：[方案与依据](./plan.md)、[实施任务及验收入口](./implementation.md)、[术语表](../../../GLOSSARY.md)。实现定位细节保留在实施任务中，本规格不依赖具体源码路径。
- 外部资料核查时点与结论见方案「外部能力核查」与[研究笔记](./research-tts-public-sources.md)（2026-11-10）；研究环境无法访问公开源页面，仓库名/文件清单/tag/commit 均为预期值，逐字节一致性与 SHA-256 属于实施阶段独立下载核对（笔记第 7 节清单），未以页面信息代替。
- 票据状态以 GitHub issue 为准；本地保留方案、实施任务与领域文档。代码实施尚未开始。
