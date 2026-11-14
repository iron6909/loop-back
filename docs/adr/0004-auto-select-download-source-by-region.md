# 下载源按系统地区自动判定，不提供手动选择

2026-11-14 确认：语音识别、语音合成、词典与发音库的公开模型下载源**不提供用户选择**——进程启动时按系统地区解析一次：中国区用 `hf-mirror.com`，其余地区用 `huggingface.co`。

此前（2026-11-10，词典与发音库去 EchoLoop 化 D3/Q14）决定「不做按地区自动默认」，只给手动切换。实际使用暴露两层问题：中国区用户装完应用后四个模块（ASR / 词典 / 发音库 / TTS）都默认走 `huggingface.co`，失败之后才去翻设置；同时「手动选来源」本身是把网络环境的判断成本推给用户——用户并不知道自己该选哪个，也不知道两者内容一致。两个来源版本与摘要完全相同（同一 `revision` + 逐文件 SHA-256），地区只决定域名，因此自动切换没有正确性风险。

实现要点：

- 复用既有地区判定 [`isChinaUserProvider`](../../lib/features/user_region/user_region_providers.dart)：系统国家码（`PlatformDispatcher.instance.locale.countryCode == 'CN'`）同步可得，首帧即有结论，不访问网络；开发者地区覆盖（`UserRegionOverride`）同样生效。
- 解析收敛到一个纯函数 [`defaultDownloadSourceForRegion`](../../lib/services/asr/asr_model_catalog.dart)，由 `offlineAsrSettingsStateFromPrefs` 在构造设置状态时调用一次；四个模块共用同一份状态里的 `downloadSource`。
- **每条安装路径都必须显式把源传下去**：真机自测发现 Kokoro / Piper 的 provider 调用 `downloadModel(...)` 时没传 `source`，命中默认参数（始终上游）——即“地区选源”对 TTS 其实从未生效（旧的手选开关也一样）。已改为从设置状态读取并传入，并用 provider 层测试（中国区断言传给管理器的是镜像）锁住。这类“默认参数静默绕过策略”的坑，今后新增下载入口时必须同步补一条断言。
- **删掉手选入口**：语音识别设置页的「模型来源」展开卡与词典设置页的同名入口一并移除；同时删除 `setDownloadSource` / `setDownloadSourceAuto` 与偏好键 `offline_asr_download_source` 的读写。模型行仍展示「来源：<域名> · 许可：…」，让用户看得见当前走的是哪条链路。
- 旧版本残留的手选偏好**被忽略**（不迁移、不清除）：源只由地区决定，因此升级后中国区用户会从「手选上游」自动变为镜像。

约束与后果：

- 地区在进程启动时固定（`UserRegionBootstrapResult`），运行期不重新探测；切换开发者覆盖后需重启进程才作用到已加载的设置状态。
- 确定性回落：镜像返回 404/410（没同步该 `revision` 或文件）或 5xx（镜像自身故障）时，用上游自动**重试一次**（`withUpstreamFallback`，覆盖 ASR / TTS / 词典 / 发音库四条安装路径）；除此之外的失败——超时、DNS/TLS/连接失败、读中断、取消——**一律不回落**：它们属于本地网络波动，而中国区访问上游本就不通，回落只会让用户多等一次超时。
- 回落只发生一次且不改变信任链：上游与镜像的 `revision`、文件 SHA-256 完全一致，回落不会引入未校验内容；落回不成功仍按原错误上抛并展示。
- 诊断与支持以日志为准：下载日志里带实际域名与 `statusCode`，能看到是否发生了回落。
