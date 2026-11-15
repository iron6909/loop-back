# 环境须知

跑构建、真机验收与全量测试前先看这篇。这里只记「配置里看不出来、踩过一次还要再踩」的坑；
能从 `pubspec.yaml`、CI 或脚本里读到的，不在这里重复。

## 工具链

- **Flutter 3.41.5**：CI 固定这个版本（`ci.yml` 的 `FLUTTER_VERSION`）。本地版本不同时，
  先对齐再判断「是不是我改坏了」。
- **JDK 17**：Android 构建需要 11+。本机 `JAVA_HOME` 可能仍指向 corretto8，导致 AGP 直接失败；
  用 `flutter config --jdk-dir <corretto17 路径>` 固定。

## Android 真机

- 安装用 `adb install -r --no-streaming`。streaming 模式在部分设备（vivo）推包后不回包，
  命令会挂到超时，但安装其实已经生效。
- 因此**验收以 `dumpsys package <包名>` 的 `versionName` / `lastUpdateTime` 为准**，不以
  `adb install` 的返回值为准。
- Maestro CLI 多数机器没装，`scripts/test_maestro_android.sh` 跑不了；改用 adb 手工脚本，
  并在任务记录里如实写明「未跑 Maestro」。

## Windows 宿主

- 本机 `core.autocrlf=true` 且仓库无 `.gitattributes`：工作区是 CRLF，`dart format` 保留
  CRLF，Linux CI 保留 LF，两边都能过格式门禁，不用手工转换。
- 没有 `touch`、`zip` 这类宿主工具。测试里需要改时间戳或打包时用 Dart API，或加 PowerShell
  分支（参考 `test/services/temp_cleanup_service_test.dart`）。

## 全量测试

- 用 `flutter test --concurrency=1`。多个测试文件共享平台插件、全局 provider 和测试数据库，
  并发执行会跨文件互相污染。
- Windows 上 native 播放器与 SQLite 会短暂占用文件句柄，清理临时目录用
  `test/helpers/temp_dir_cleanup.dart` 的重试版，别直接 `deleteSync`。
