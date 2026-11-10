# 语音合成去 EchoLoop 化 · Android 真机验收报告（#25）

> 2026-11-10。依据 [spec](./spec.md) 与 [implementation.md](./implementation.md) 的 I5。
> 证据以 adb + uiautomator 采集，截图与日志存系统临时目录（`C:\Users\Banko\AppData\Local\Temp\tts-25-verification\`），不进仓库。

## 环境

- 设备：vivo V2055A（`15767646010086V`，Android 14，PD2055），与 ASR #13 验收同机。
- 宿主：Windows 11 + WSL2，`flutter 3.47.9`（Dart 3.13.7），Java 17（corretto17，Gradle 需要 11+）。
- 包：`app.echoloop.dev`（dev flavor），versionCode=1，versionName=1.0.44。
- Maestro 不可用；按仓库既有做法用 adb + uiautomator（Flutter 语义经 `content-desc` 暴露）。
- Apple（iOS/macOS）编译与原生集成测试在 Windows 宿主不可执行，如实记录为未验证，不宣称通过。

## 构建与安装

- 首次构建需先 `flutter pub get`（新 worktree 无 `.dart_tool` 与插件清单，`--no-pub` 会因
  `:integration_test` 模块缺失失败）。
- `flutter build apk --debug --flavor dev --target-platform android-arm64 --no-pub` 成功，
  产物 `build/app/outputs/flutter-apk/app-dev-debug.apk`（198,634,618 字节）。
- `adb install -r` 安装成功，`dumpsys package` 显示 `lastUpdateTime=2026-11-10 15:55:58`，
  versionCode=1。

**vivo 安装弹窗（同版本重复安装被系统拒绝）**：同一 APK 重复 `adb install -r` 时，
vivo 弹「USB 安装」确认框，约 12 秒未点击即自动取消，`adb install` 返回
`Failure [INSTALL_FAILED_ABORTED: User rejected permissions]`。处理方式与仓库既有经验一致：
安装前/同时用 `uiautomator dump` 找到确认弹窗的「继续安装」按钮并 `input tap`；本次最终以
一次成功安装为准（15:55:58），未再重复安装。已装包（versionCode=1）包含本票全部修复
（见下「发现并修复的问题」）。

## 逐项验收

### 1. 界面去品牌与真实身份（验收边界「界面」）

`uiautomator dump` 核对 TTS 设置页：

- 无 "Echo Loop" 字样（仅系统包名 `app.echoloop.dev`，非用户可见文案）。
- 引擎名：`Piper` / `Kokoro`（不再有 Echo Loop AI 前缀）。
- Kokoro 变体如实显示：`全精度 (fp32)`（就绪 · 352 MB）与 `量化 (int8)`（就绪 · 151 MB）。
- 来源与许可行可见：
  - Kokoro：`来源：iron6909/loop-back-models（GitHub Release） · 许可：Apache-2.0 · espeak-ng-data GPL-3.0-or-later`
  - Piper 逐音色：Amy `csukuangfj/vits-piper-en_US-amy-medium · CC BY-SA 4.0`、
    Ryan/Joe/Hannah `iron6909/loop-back-models（GitHub Release）· CC BY-NC-SA 4.0 / CC0 / CC BY-NC-SA 4.0`、
    Kristin `csukuangfj/vits-piper-en_US-kristin-medium · public domain`。
- 下载来源切换项：`公开上游` / `hf-mirror.com`（radio，可切换）。

### 2. lessac / alan 不可再分发（规格 D5）

- Lessac（美音）：`不可下载 · Blizzard 2013 Research Licence (redistribution not permitted)`，
  无下载按钮。
- Alan（英音）：`不可下载 · All Rights Reserved (redistribution not permitted)`，无下载按钮。
- 二者仅保留目录身份，未安装时试听入口不提供下载/重试。

### 3. 公开源下载（验收边界「去耦」「本地模型」）

- **Kokoro Full precision（fp32）**：从公开源 `iron6909/loop-back-models` GitHub Release 下载
  成功并安装，日志：
  `下载完成 uri=https://github.com/iron6909/loop-back-models/releases/download/tts-models/kokoro-en-v0_19.tar.gz bytes=313785757`
  → `archive verified` → `install finished`，设置页 `就绪 · 352 MB`。
- **镜像下载**：下载来源切到 `hf-mirror.com` 后，Piper HF 音色 Kristin 从镜像下载成功：
  `url=https://hf-mirror.com/csukuangfj/vits-piper-en_US-kristin-medium/resolve/6fdc68.../en_US-kristin-medium.onnx bytes=63531507`
  与 `tokens.txt bytes=940`，设置页 `就绪 · 61 MB`。随后切回 `公开上游`。
- **3 个重打包音色选镜像仍走上游**（D8）：ryan / joe / hfc_female 均为
  `githubReleaseAsset` 布局、无已核实镜像；在 hf-mirror.com 选中状态下下载 URL 仍为
  `https://github.com/iron6909/loop-back-models/releases/download/tts-models/vits-piper-en_US-{ryan,joe,hfc_female}-medium.tar.gz`
  （bytes 67370820 / 67329430 / 67359748），UI 无失败。
- **espeak-ng-data 共享依赖只补行为**：Piper HF 音色（Kristin）主文件从镜像下载后，共享
  espeak 依赖单独从 GitHub 上游下载（`espeak-ng-data.tar.gz bytes=8986848`，无镜像），
  不重下模型本体。损坏修复场景（第 5 项）进一步验证只补 8.9 MB espeak、不重下 67 MB 模型。

### 4. 试听与离线合成（验收边界「去耦」）

- **在线试听**：设置页选中已装音色 Amy 试听，`PiperTts init` + 播放正常。
- **离线合成**：`adb shell svc wifi disable` + `svc data disable`（`Active default network: none`）后，
  删除 `cache/tts_cache/` 目录再试听 Amy，日志显示
  `用户发音缓存未命中，准备合成` → `PiperTts ⏱ load=1329ms generate=560ms writeWave=0ms`
  → `✓ synthesize ok .../cache/tts_cache/<key>.wav` → `文本合成结束 结果=成功` → `开始播放`。
  断网状态下真实合成并播放成功，且 `tts_cache/` 目录被自动重建——同时验证了解除
  EchoLoop 域名的运行时依赖与缓存目录修复（见下）。
- 试听后已恢复网络（`svc wifi enable` + `svc data enable`）。

### 5. 损坏修复（验收边界「本地模型」「迁移」）

`adb shell run-as app.echoloop.dev rm -rf files/tts-models/en_US-ryan-medium/espeak-ng-data`
后重启应用 → 重新扫描：Ryan `刷新内存状态 ... manifest=matched filesReady=false after=notDownloaded`
→ 设置页回到 `未下载` 并给下载入口 → 点选该音色触发
`downloadModel(repair espeak)` → 仅下载 `espeak-ng-data.tar.gz`（8,986,848 字节）→ 状态回到
`就绪 · 77 MB`。不触碰其它模型与用户数据。

### 6. 回归：单词卡发音（验收边界「本地模型」）

收藏 → 句子 → 点选单词 `headlines` 打开词典，点发音（volume_up）按钮：
`用户发音结束：AudioPlaybackResult.completed 缓存键=headlines`，用已装 Piper（Amy）正常朗读。
此前 `latest` 一词也验证朗读成功。断网 + 清缓存后 Amy 试听合成成功（第 4 项）已覆盖离线合成。

## 发现并修复的问题（代码改动）

本票以设备证据为主，代码改动仅限验收发现的 2 个问题，提交 `4cdb48c2`：

1. **损坏模型被误报就绪**：`kokoro/piper_model_provider.dart` 的 `ensureDownloaded`
   仅凭 `install.json` 清单就 `markReady`，导致 espeak-ng-data 等关键文件被外部删除后，
   点选音色即被误报「就绪」、修复入口消失。改为同时校验 `manager.isModelDownloaded()`
   （关键文件齐全），缺失则走修复下载。
2. **TTS 缓存目录被系统清理后合成失败**：`tts_cache_store.dart` 的 `_dir()` 把
   `tts_cache` 目录缓存后不再校验存在性；Android 缓存目录是 transient 产物，被系统清掉后
   `sherpa.writeWave` 因父目录不存在而失败（`writeWave failed`），且目录不再重建。改为只缓存
   基目录解析结果，每次调用仍校验并重建缺失的 `tts_cache/`。

测试：`flutter analyze`（改动文件）0 issue；
`flutter test test/providers/tts/kokoro_model_provider_test.dart test/providers/tts/piper_model_provider_test.dart test/services/tts/tts_cache_store_test.dart`
41 通过、1 失败——失败项 `TtsCacheStore cleanup 清扫孤儿文件但保留被引用的有效文件`
为既有 Windows 宿主路径分隔符基线（`dir.list().path` 的 `\` 与 DB 中 `/` 路径不匹配），
与本票改动无关（`_sweepOrphanFiles` 未改动），按 TASKS.md 既有 Windows 基线记录，不称全绿。

## Apple 编译（如实记录，未验证）

- iOS/macOS 编译与原生引擎集成测试需 macOS 宿主，本票 Windows 宿主不可执行，未执行、未宣称。
- 共享 `lib`/`test` 的 `flutter analyze` 与定向测试已在 Windows 上通过；Apple 侧既有功能
  维持「未验证」，待具备 macOS 宿主时补齐（D6 边界）。

## 结论

- Android 真机公开源下载（含上游/镜像切换）、镜像下重打包音色仍走上游、espeak 只补、
  离线试听与合成、损坏安装修复、界面去品牌与单词发音回归均通过并留档。
- 2 个验收发现的设备问题已修复并有回归测试。
- 同版本重复安装被 vivo 系统拒绝的坑已按仓库经验处理；Apple 编译未验证，未宣称通过。
