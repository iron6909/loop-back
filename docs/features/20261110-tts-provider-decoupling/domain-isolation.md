# TTS 正常流程域名隔离核查（issue #24）

> 核查日期：2026-11-10。依据 issue #24 验收标准「代码级确认下载、合成、试听、缓存路径无
> EchoLoop 域名引用」，对 TTS 正常流程（下载/合成/试听/缓存/管理器/目录）做源码级
> grep 核查。本记录只陈述结论与残留清单，不构成运行时或网络证据（真机抓包属 #25）。

## 结论

**TTS 正常流程（下载、合成、试听、缓存、管理器、目录）已无 `cdn.echo-loop` /
`modelCdnUri` 引用。** 本地引擎（Kokoro/Piper）的下载地址由
`lib/services/tts/kokoro_model_catalog.dart`、`piper_model_catalog.dart`、
`tts_shared_resource_catalog.dart` 的公开资源目录（`AsrPublicResourceSpec`）构造，
经 `iron6909/loop-back-models`（GitHub Releases）与 `csukuangfj/*`（Hugging Face
resolve）落地；模型管理器不再经过共享 `RegionalServiceEndpoints.modelCdnUri` 路由。

核查命令（在 worktree 根）：

```bash
grep -rniE "echo[-_.]?loop\.(top|cn)|cdn\.echo-loop|modelCdnUri" \
  lib/services/tts lib/providers/tts
# 结果：无匹配（exit 1）
```

## 残留清单（均不在本票 TTS 正常流程范围内）

| 位置 | 内容 | 处理结论 |
| --- | --- | --- |
| `lib/services/tts/platform_tts_engine.dart` | `top.echo-loop/tts_synth` | **原生 MethodChannel 契约**，非域名/资源路由；平台 TTS 不下载模型，不在本票范围（issue #24 明确排除） |
| `lib/config/regional_service_endpoints.dart` | `cdn.echo-loop.top` / `cdn.echo-loop.cn` | 共享 CDN 配置，仍被词典等非 TTS 资源复用（D7 另行立项），TTS 已不再引用 |
| `lib/services/runtime_endpoint_router.dart` | `modelCdnUri` | 共享路由方法，仅剩词典/发音库调用方使用；TTS 管理器已移除对其的 import |
| `lib/services/dictionary_download_manager.dart` | `modelCdnUri` | 词典资源（D7 范围外，另行立项） |
| `lib/services/pronunciation/pronunciation_library_manager.dart` | `modelCdnUri` | 发音库资源（非 TTS 合成流程，另行立项） |
| `lib/providers/tts/tts_settings_provider.dart` | `legacyEchoLoopEngineValue = 'echoLoop'` | 历史偏好值迁移兼容（读到 `echoLoop` 映射为 `kokoro`），非域名引用，必须保留 |
| `lib/screens/tts_settings_screen.dart` | `isEchoLoop`、`l10n.ttsEngineEchoLoop` 等 | 设置页去品牌文案，属 #23 范围；本票不触碰 |

## 附：TTS 相关代码注释中的品牌名

`lib/services/tts/tts_engine.dart`、`kokoro_voices.dart`、`tts_settings_provider.dart`
等文件仍存在「Echo Loop AI Advanced / Echo Loop（Kokoro）」等注释文案。这些是
D4 品牌去话与 #23 的设置页/文案职责（含 ARB），不在本票「域名隔离」核查范围；本票
只保证运行时 TTS 正常流程不依赖 EchoLoop 域名，未扩大为整应用更名。
