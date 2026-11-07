# 语音识别去 EchoLoop 化：公开本地模型与可配置在线转写

> 规格日期：2026-11-07。依据已确认的 D1–D13 决策整理，业务实现尚未开始。
> 发布状态：已发布至 [GitHub issue #1](https://github.com/iron6909/loop-back/issues/1)，已应用 `ready-for-agent`。

## Problem Statement

英语学习者需要稳定地为学习材料生成字幕，并把自己的跟读、复述录音转换为文字。当前三个本地模型以 Echo Loop AI 的 Fast、Balanced、Accurate 名称展示，实际已经是公开的 Whisper 英语模型，但下载模型及其配套 VAD 仍依赖 EchoLoop 的资源服务。用户难以判断模型的真实来源，原服务不可用时，新设备的模型安装也会受影响。

用户还无法按识别用途配置在线转写：长材料字幕、短句跟读与段落复述具有不同的速度、资源和结果要求，不能只用一个统一档位表达。字幕转录需要适合逐句播放的时间片段，而练习录音转写主要需要文本；只证明某模型能返回文字，不能证明它是字幕可用模型。

改造还必须保护已有模型、字幕和学习记录。配置变化、网络失败或备份恢复不能导致录音被意外上传、重复计费、旧结果覆盖新结果，或把语音识别失败误判为学习者表达错误。

## Solution

继续使用现有 Whisper Tiny、Base、Small 英语 ONNX 模型和 sherpa-onnx 引擎，以真实模型名称、公开出处和许可信息呈现；将 ASR 与配套 VAD 的必需资源迁往固定版本的公开来源，并提供一个可手动切换的镜像。已安装且有效的模型继续使用。

提供 OpenRouter 预设和通用 OpenAI 兼容文件转写接口。用户可分别为学习材料字幕、跟读录音和复述录音选择识别方式及模型；三个用途共用一份在线语音服务地址和 Key，但可以使用不同在线模型。语音服务与文字 AI 的配置和凭据独立。

保留现有默认方式，在线由用户主动启用，并在首次测试或上传前完成告知。字幕仅接受已经验证能返回有效片段时间戳的模型。长音频按块处理、失败后由用户继续未完成部分，全部成功后一次性保存。首期面向英语与 Android 真机验收，保持 iOS/macOS 的可编译性和既有功能。

## User Stories

1. As an English learner, I want to see the real Whisper model names and their public origins, so that I understand which technology performs recognition.
2. As an English learner, I want to choose among Whisper Tiny, Base, and Small, so that I can balance recognition quality with my device resources.
3. As a new user, I want to install recognition models without relying on EchoLoop's resource service, so that the original product's availability does not determine whether I can study.
4. As a user with limited network access, I want to switch between a public model source and a clearly identified mirror, so that I can use a reachable download source.
5. As a user downloading a model, I want progress, cancellation, and actionable errors, so that I can control a large download.
6. As a user downloading a model, I want incomplete or corrupted files to be rejected while a working installation is retained, so that a failed download does not break recognition.
7. As a returning user, I want my existing valid model installations to remain usable after upgrading, so that I do not have to download the same models again.
8. As a returning user, I want only a missing shared VAD resource to be downloaded, so that I do not waste bandwidth downloading an already installed Whisper model.
9. As an offline learner, I want installed local recognition to keep working without an online account or API Key, so that basic study remains available offline.
10. As an English learner, I want separate recognition choices for subtitles, shadowing, and retelling, so that each activity can use the most suitable approach.
11. As an English learner, I want each activity to remember its local and online model choices, so that changing recognition mode does not erase my preferences.
12. As a returning user, I want my valid existing recognition preferences and platform defaults to be preserved, so that upgrading does not unexpectedly change my workflow.
13. As an online-service user, I want to transcribe without first downloading a local model or VAD, so that online recognition does not require an unrelated large installation.
14. As a shadowing learner, I want online recognition to process my recording after I stop recording, so that I can receive a final transcript using my chosen model.
15. As a user of supported system recognition, I want existing real-time shadowing feedback to remain available, so that I retain the feedback my platform already provides.
16. As a retelling learner, I want my selected retelling model to actually produce the transcript, so that the application does not silently reuse a result from a different model.
17. As a retelling learner, I want recognition failures to stop the evaluation with a clear error, so that technical failures are not treated as mistakes in my English.
18. As a retelling learner, I want an applicable transcript and evaluation to be reused for the same attempt, so that I avoid unnecessary processing and charges.
19. As an OpenRouter user, I want a preset for its dedicated speech-to-text service, so that I can configure recognition without constructing an integration myself.
20. As a user of another compatible provider, I want to enter its service root address and model ID, so that I can use an OpenAI-compatible transcription service.
21. As an AI-service user, I want speech and text AI settings to remain independent, so that changing speech recognition does not disrupt translation, explanations, or chat.
22. As a user configuring online speech, I want the three recognition activities to share one speech-service connection while allowing different models, so that I avoid repeatedly configuring the same provider.
23. As a privacy-conscious user, I want API Keys to stay out of ordinary preferences, backups, logs, and analytics, so that credentials are not exposed through those channels.
24. As an AI-service user, I want to clear or replace a speech Key without changing my text AI Key, so that credential management has predictable effects.
25. As a user selecting an online model, I want to enter a model ID manually even if discovery is unavailable, so that a provider's model-list endpoint is not required.
26. As an OpenRouter user, I want to refresh a list of transcription models, so that I can find relevant models instead of guessing among general chat models.
27. As a user configuring speech recognition, I want to test with a supplied short recording after being informed about upload and possible charges, so that I can verify the service without exposing my own recording.
28. As a user generating subtitles, I want text recognition and subtitle timestamp support to be reported separately, so that I do not select an unsuitable model based on a generic connection-success message.
29. As a user changing a service address, Key, or model, I want the relevant old validation results to become invalid, so that validation does not describe a different configuration.
30. As a user of a verified configuration, I want applicable verification results to be reused across activities and ordinary restarts, so that I do not repeatedly pay for the same test.
31. As a privacy-conscious user, I want to know which service and downstream provider receive audio before the first request, so that I can make an informed choice.
32. As a regular online-service user, I want subsequent operations to show the selected service and model without repeating the same confirmation, so that routine study remains convenient.
33. As an online-service user, I want reported usage and costs to be distinguished from unknown charges, so that missing billing data is not presented as free usage.
34. As a local-recognition user, I want local failure to remain local unless I choose otherwise, so that my audio is not uploaded unexpectedly.
35. As a paying online-service user, I want failures to avoid automatic retries or silent provider changes, so that I retain control over additional charges.
36. As a user encountering an online error, I want to distinguish missing configuration, authentication, balance, model compatibility, limits, and network failures, so that I can take the appropriate next step.
37. As a user retrying an interrupted request, I want to know that a timed-out chunk may already have been charged, so that I understand the cost of retrying it.
38. As a learner using long audio, I want bounded sequential transcription with visible progress, so that large materials can be processed within service limits.
39. As a learner whose long transcription failed partway through, I want to retry only unfinished chunks while the application process remains alive, so that successfully processed audio is not uploaded again.
40. As a learner running a transcription, I want to close and reopen its dialog or visit another page without losing the task, so that I can continue using the application.
41. As a mobile user, I want the limits of background execution and recovery after the app is killed to be clear, so that I do not mistake an in-memory task for a durable background job.
42. As a user canceling transcription, I want future uploads to stop and temporary results to be cleaned up without deleting the original media, so that cancellation protects my material.
43. As a user changing recognition settings, I want to be informed about affected running tasks and retain the existing settings if I decline the change, so that I can avoid interrupting work unintentionally.
44. As a learner with existing subtitles, I want replacement subtitles to be saved only after the complete task succeeds, so that partial or failed recognition does not destroy a usable transcript.
45. As a learner editing or importing subtitles while recognition is running, I want the old task to detect the conflict before saving, so that it does not overwrite my newer work.
46. As a learner using sentence playback, I want valid segment timing and complete sentence reconstruction, so that subtitles remain suitable for sentence-level study.
47. As a learner viewing word timing, I want model-provided, estimated, mixed, and unknown timing to be represented accurately, so that estimated timing is not presented as precise alignment.
48. As a learner using long or repetitive material, I want words across chunk boundaries and genuinely repeated phrases to be preserved, so that merging does not omit or duplicate learning content.
49. As a learner using recordings with silence, I want confirmed silent chunks handled appropriately and unrecognized speech reported as failure, so that content is not silently lost.
50. As a returning learner, I want saved subtitles, recordings, and study records to remain unchanged when I switch models, so that historical work is only replaced when I explicitly request recognition again.
51. As a user creating a backup, I want useful configuration and learning data included while Keys, validation records, and temporary tasks are excluded, so that the backup is useful without carrying credentials or invalid runtime state.
52. As a user restoring a backup, I want online recognition to require fresh credentials and verification without automatically uploading or changing modes, so that restoration does not trigger unintended activity.
53. As a user whose restore fails, I want the previous configuration and credentials restored consistently or a clear failure reported, so that the application does not retain mismatched service addresses and Keys.
54. As a user with historical subtitles, I want their existing source meanings and contents preserved, so that legacy material is not relabeled as newly generated online content.
55. As an Android learner, I want model downloads, local recognition, online recognition, cancellation, and recovery tested on a real device, so that desktop tests are not mistaken for proof of mobile reliability.
56. As an iOS or macOS learner, I want the existing application and recognition paths to remain functional, so that this Android-focused change does not remove supported behavior.

## Implementation Decisions

1. **本地模型身份与执行方式。** 保留三种 Whisper 英语 INT8 ONNX 模型、现有内部 ID 和 sherpa-onnx 引擎。展示 Whisper Tiny / Base / Small（English）、公开出处、许可和资源信息。名称变化不触发模型身份、安装目录或用户数据重建。

2. **公开资源分发。** ASR 资源目录记录固定 revision、逐文件 SHA-256、大小、许可和共享依赖。默认公开上游与手动镜像使用相同资源身份；Whisper 的上游采用 Hugging Face，镜像明确标识为 hf-mirror.com。VAD 同样必须具有固定公开来源和校验依据。下载器保留临时安装、校验、取消、失败清理及原子发布，只有完整成功后才发布新安装；跨来源续传无法证明身份一致时重启该文件。已安装有效模型与历史安装迁移继续兼容，缺 VAD 只补依赖。其他资源使用的公共基础设施不因 ASR 去耦被删除。

3. **按识别用途配置。** 字幕、跟读、复述各自维护方式、本机模型和在线模型选择；设置页与字幕入口共用同一状态。新装字幕/复述保持本机，跟读保持 Android 离线、Apple 平台识别的现有规则；有效旧偏好优先于默认值。没有独立复述偏好时，以升级前解析出的字幕模型初始化本机复述配置。系统识别仅在支持的平台和用途提供，不宣称系统识别一定离线。在线分支不要求安装本地模型或 VAD。

4. **语音与文字服务隔离。** 按已接受的配置隔离 ADR，语音和文字 AI 使用独立普通配置、独立安全 Key 与独立请求生命周期。语音内部只维护一份在线服务类型、地址和 Key，三个用途可选不同在线模型。用户可以分别填写相同 Key，不建立自动共享引用。地址或服务类型变化清除旧语音 Key，单改模型保留 Key；配置变更只作废受影响任务和验证。

5. **在线服务契约。** 首期接入 OpenRouter 预设及通用 OpenAI 兼容专用转写接口，使用现有 HTTP 依赖发送 multipart 文件转写请求。Base URL 的含义是直接追加 `/audio/transcriptions` 的根路径，保留合法子路径，不自动添加 `/v1`；OpenRouter 根路径为 `https://openrouter.ai/api/v1`。文本用途请求 JSON 转写，字幕用途请求 `verbose_json` 与片段时间戳；请求语言为英语。词时间戳参数仅用于已确认支持的配置。在线协议不复用文字聊天请求体、自有后端身份或会员门控，不通过普通音频聊天结果冒充字幕。

6. **模型发现与验证。** 模型 ID 始终可手填，OpenRouter 可主动刷新 STT 目录；发现失败不阻止配置，自定义服务不强制提供模型列表。配置可先保存，启用在线用途前需具备 Key、上传告知和适用能力验证。使用有许可的随包英语短音频，由用户主动触发测试，分别记录文本、片段及适用的词时间戳能力。验证绑定非秘密配置身份并保存在本机，适用时跨用途和普通重启复用；地址、Key、模型变化后相关结果失效。凭据版本独立管理，不把 Key 的明文或派生摘要写入普通存储。目录存在或文字聊天成功不算语音能力验证，每次正式结果仍要校验。

7. **字幕与转写准入。** 练习录音转写要求有效非空文本；字幕可用模型还必须返回有效片段时间戳。时间必须有限、顺序与起止合法，并处于对应音频范围内；集中处理合理舍入容差，不能把明显越界修正为成功。纯文本或只有词时间戳的模型可用于文本转写，首期不用于字幕。片段有效而词时间戳缺失或无法有效对应文本时，保留有效部分并对受影响片段合成词级时间戳，明确记录来源。继续使用完整句还原及可选短句合并，不将必要的句内估时宣称为模型对齐。

8. **长音频编排。** 在现有音频转换边界增加有界区间提取和取消，保留源媒体，同时限制每块字节数与时长，顺序上传。不得把本地 Whisper 的推理窗口当作在线服务限制。切点优先选邻近静音；硬切时用短重叠和边界局部对齐，字幕时间加上真实块偏移，不对全文进行字符串去重。纯文本录音需要分块时也验证拼接完整性。确认无声的块可以跳过；有声或无法确定的块返回空结果应失败，整份无语音则显示无可识别语音，不覆盖字幕。

9. **任务、重试与取消。** 字幕任务由既有任务管理器在进程内持有成功块及输入/配置身份，页面或弹窗关闭不清除可续试任务。失败停在当前块，用户只重试未成功块；不同输入或配置的块不得混用。主动取消、删除材料、接受相关配置变更时结束任务，停止后续请求并清理本模块临时结果。录音转写由练习会话持有，保留 attempt/session/generation 守卫，过期回调不得覆盖新状态。取消传到支持取消的转换及网络边界，但不承诺撤回供应商已处理请求的费用。首期没有可靠系统后台执行或进程重启恢复。

10. **跟读与复述接线。** 在线跟读在停止录音后转写，避免多个后端重复生成同一最终结果；现有支持的平台实时跟读反馈保留。复述只复用同 attempt 且实际识别身份符合所选配置的转写，否则按复述自己的选择执行。识别失败不进入复述评估，评估仍使用独立文字 AI。实际文本与既有评估缓存身份一致时可以复用评估，不因来源标签变化无条件重复收费。已保存结果保持原样，只有显式重新识别才产生替换结果。

11. **来源与数据库迁移。** 保持既有转录来源整数 local=0、ai=1、device=2，追加 online=3 表示用户供应商转写；历史 ai 也用于随包示例，不重解释为本次在线请求。增加可空的字幕整体词时间戳来源，区分模型提供、估算和混合；旧数据缺少标记时为未知。界面依据实际来源提示，不能因为转录来自在线就宣称逐词精确。在实施时的最新数据库版本追加迁移，保留既有字幕、学习记录、收藏和来源值。

12. **原子提交与冲突。** 扩展现有字幕持久化事务，一次写入字幕、词时间戳、来源、语言和相关计数，成功后再刷新内存。提交前检查任务有效性，在事务内检查目标字幕是否已被其他操作替换；冲突则保留用户较新的结果。只有全部分块成功并通过合并校验才提交。提交前取消不写库；提交已开始则按事务结果完成，不出现界面报告取消但字幕已经被覆盖的状态。

13. **凭据与备份恢复。** 普通用途选择和服务配置可进入既有备份，所有 Key、能力验证、临时任务和模型下载缓存均排除。恢复前停用客户端并清除语音、文字两份 Key；失败回滚恢复原配置和凭据，安全存储错误必须明确处理，不能继续使用错配状态。恢复成功要求重新填写 Key 和验证，不自动测试、上传或切换方式；本机可用模型继续保留。保持既有高版本备份不能导入低版本应用的规则。

14. **告知、错误与费用。** 首次向某语音服务发送测试或用户音频之前告知上传目标、下游推理供应商及可能收费；服务地址变化重新告知，后续操作显示服务与模型并避免重复确认。展示未配置、验证中、文本可用、字幕可用、不兼容、任务进行中、可续试失败、提交中、成功和取消等实际状态。区分鉴权、余额、地址/模型、限流、大小、能力、服务与网络错误。只展示收到的用量和费用，缺失或结果不确定部分标为未知，不按免费处理。无自动付费重试、参数变换重发或供应商回退，本机失败也不自动上传。

15. **实现范围与复用。** 修改既有 ASR 资源管理、用途设置、字幕任务编排、录音控制、复述评估衔接、字幕持久化和备份恢复模块；新增最少必要的在线语音配置与转写客户端。复用已有下载、HTTP、音频转换、字幕后处理和状态管理能力，保持单向数据流与副作用注入。首期英语、Android 真机优先，保持 iOS/macOS 可编译与既有功能；设备上尚未验证的在线能力不得宣称已验收。

## Testing Decisions

1. **以外部行为为标准。** 好的测试从用户可触发的公开操作出发，观察任务状态、实际请求、持久化内容及失败后的数据保留。网络请求次数只用于验证上传或计费行为，不断言无关私有方法调用顺序、组件结构、字号、颜色或间距。

2. **最高既有业务边界优先。** 主测试边界位于字幕任务管理器与跟读/复述控制器的公开入口：从开始识别、停止录音、取消、重试或配置变更，覆盖到最终结果和写库。沿用现有入口，不为测试引入一个新的通用业务门面。对同一行为不在每一层重复编写镜像测试。

3. **复用副作用注入。** 使用现有离线引擎工厂、音频转换接口、HTTP adapter 和文件操作注入点；新增在线客户端接受同层 transport 注入。尽量组合真实配置、解析、后处理与内存数据库，只替换模型推理、网络、平台录音等不可控边界。现有本地字幕任务与语音录音控制器测试是主要先例。

4. **资源安装专项。** 通过模型管理器的公开安装操作，使用受控下载响应和真实临时目录，覆盖固定资源身份、错误摘要、中断、取消、镜像切换、原子替换、旧缓存迁移及 VAD 单独缺失。复用现有 ASR 模型管理器测试的边界；不通过模拟内部校验函数来证明文件完整性。

5. **配置与凭据专项。** 通过配置保存/读取与任务入口验证三个用途相互独立、语音与文字服务隔离、缺 Key 和验证失效、仅取消受影响任务。沿用现有供应商配置存储及 provider 配置生命周期测试，使用受控安全存储；断言凭据不出现在普通配置、备份或日志内容中。

6. **在线协议与能力。** 从真实在线客户端发请求到假 HTTP adapter，检查正确上传格式、模型、英语及用途参数，模拟成功、文本可用但无时间戳、格式错误、401/402/404/429/413、5xx、超时和取消。能力测试必须验证它不会写用户字幕、不自动上传用户录音、不静默重复收费；模型列表成功不能使未测试配置变为字幕可用。

7. **字幕与分块行为。** 优先从字幕任务入口注入固定识别结果，验证完整句还原、短句合并、时间偏移、片段范围、真实重复句、跨块单词、静音和空结果。复用已有 Whisper 结果解析、合成词级时间戳及本地转录任务测试；纯算法边界只保留能够发现真实回归的专项样例。

8. **取消、续试与竞态。** 用可控 Future 和响应顺序，覆盖两块成功后一块失败只重试未完成部分、重开弹窗保留任务、取消后不开始下一块、配置变化作废旧回调、不混合不同输入的块。避免任意延时等待。参考既有录音控制器、供应商切换和字幕任务取消回归。

9. **转写与评估分离。** 在跟读/复述公开操作边界验证所选模型实际执行、同 attempt 来源匹配才复用、识别失败不调用评估、相同实际文本可复用适用评分、旧结果不能覆盖新 attempt。沿用已有复述评估缓存身份和录音会话隔离测试。

10. **数据与恢复真实往返。** 使用真实内存数据库和备份导入流程，验证字幕及元数据同事务、提交失败回滚、用户并发导入字幕冲突、来源整数兼容、词时间戳来源迁移、Key 排除、恢复成功重验及恢复失败回滚。现有字幕 DAO、本地转录任务和供应商备份恢复测试是先例；数据库事务不以 mock 的成功调用代替。

11. **界面与平台。** 使用现有识别设置及字幕管理界面的 widget 测试验证状态与操作：在线无本地模型可用、时间戳准入、首次告知先于测试、切配置前提示取消、费用未知、失败续试以及历史结果保留。Android 端到端验证公开资源安装、三种用途、离开页面、断网、取消和恢复；优先使用项目现有 Maestro 流程。保持 iOS/macOS 编译与原有行为检查，原生引擎集成测试在支持的平台 runner 上运行。

12. **测试层次与证据。** 普通自动化测试不使用真实 Key、不上传用户音频、不发付费请求。真实供应商与设备验收采用固定、有使用权的英语样本，分别报告文本完整性、时间线、耗时、内存和实际费用；HTTP 成功或短样本通过不代表长音频质量及全部设备稳定。实施按改动范围执行检查，整体交付再执行跨模块完整检查，平台阻塞明确记录。本次生成规格不构成任何运行时验收。

## Out of Scope

- 整款应用更名，以及词典、TTS、播客等非 ASR 资源的去品牌化或下载体系改造。
- 替换现有 sherpa-onnx 推理引擎，或扩展首期三档本地 Whisper 之外的新模型家族。
- 多语言学习、自动识别语言和语音翻译。
- Windows、Linux、Web 新增支持；未经实机验证即宣称 Apple 平台新增在线能力完成验收。
- 在线实时流式识别；现有系统实时跟读反馈保持原能力。
- 多套在线语音服务配置同时管理、各家专有 SDK、自建推理网关或通用插件框架。
- 语音与文字 AI 自动共享凭据，或恢复 EchoLoop 登录、会员和配额门控。
- 手动导入模型文件、任意模型资源下载 URL、未经校验的镜像内容。
- 额外强制对齐模型，以及将只有文本或只有词时间戳的模型接入首期字幕生成。
- 可靠系统后台执行、跨进程任务续跑或恢复应用被杀之前的分块检查点。
- 自动付费重试、自动切换供应商/模型、失败后自动上传或重新处理历史字幕。
- 准确费用预估、取消后的费用撤回承诺和退款流程。
- 将原有 Android 录音结束 native/VAD 崩溃视为本次已解决；相关稳定性问题继续独立跟踪，本次仍须验证兼容性。

## Further Notes

- 产品决策来自两轮已确认的 D1–D13，无新增产品访谈或范围选择。领域术语使用字幕转录、练习录音转写、实时跟读反馈、复述评估、识别用途、字幕可用模型及合成词级时间戳。
- 本地决策材料：[方案与依据](./plan.md)、[实施任务及验收入口](./implementation.md)、[配置隔离 ADR](../../adr/0001-separate-speech-and-text-provider-config.md)、[术语表](../../../GLOSSARY.md)。实现定位细节保留在实施任务中，本规格不依赖具体源码路径。
- 官方资料核查时点为 2026-11-06：[Whisper](https://github.com/openai/whisper/)、[Sherpa Whisper 分发](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/whisper/export-onnx.html)、[OpenRouter STT](https://openrouter.ai/docs/guides/overview/multimodal/stt)。OpenRouter 的专用转写接口及公开 STT 模型目录已核实；尚未进行付费转写与设备验证。实施时重新确认模型生命周期和能力，不固化某一线上模型为永久唯一选项。
- 当前仍需补齐与现有 VAD 文件身份对应的固定公开来源、许可及设备兼容证据。优先使用相同产物；若需要公开版本升级，明确记录版本变化并验证旧安装兼容，不能将模型升级描述成单纯换下载地址。这是资源切换的实施前置。
- 在线块大小约两分钟只是实施中的首个性能验证目标，须同时满足上传大小和供应商处理时限，按实际模型校准；它不是用户可见的固定时长限制，也不是新的产品选项。
- 测试主要沿用既有业务入口与副作用注入点。不同模块生命周期使资源安装和数据库事务仍需少量专项测试；不为把所有测试强塞到单一入口而新增生产抽象。
- 票据状态以 GitHub issue 为准；本地保留方案、实施任务与领域文档。代码实施尚未开始。
