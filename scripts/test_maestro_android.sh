#!/usr/bin/env bash
# Android 真机 Maestro 自动化：构建 dev 包、安装到指定设备，再运行目标 UI Flow。
# 首次使用仍需人工在手机上开启 USB 调试并授权当前电脑。
#
# 用法：
#   scripts/test_maestro_android.sh
#   scripts/test_maestro_android.sh --device <adb-serial>
#   scripts/test_maestro_android.sh --device <adb-serial> --flow maestro/study/study_tab_initial_task.yaml
#   scripts/test_maestro_android.sh --device <adb-serial> --no-build

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# 可通过环境变量固定常用设备；命令行 --device 的优先级更高。
DEVICE="${MAESTRO_ANDROID_DEVICE:-}"
FLOW_TARGET="maestro/study"
NO_BUILD=false
ENV_FILE=".dev.env"
APK_PATH="build/app/outputs/flutter-apk/app-dev-debug.apk"

usage() {
  cat <<'EOF'
Usage: scripts/test_maestro_android.sh [OPTIONS]

Build, install, and test the Android dev flavor with Maestro.

Options:
  --device <serial>  ADB serial; overrides MAESTRO_ANDROID_DEVICE
  --flow <path>      Maestro flow file or directory (default: maestro/study)
  --no-build         Install the existing debug APK without rebuilding
  -h, --help         Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || { echo "[maestro-android] --device requires a serial" >&2; exit 2; }
      DEVICE="$2"
      shift 2
      ;;
    --flow)
      [[ $# -ge 2 ]] || { echo "[maestro-android] --flow requires a path" >&2; exit 2; }
      FLOW_TARGET="$2"
      shift 2
      ;;
    --no-build)
      NO_BUILD=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "[maestro-android] Unknown option: $1" >&2
      usage
      ;;
  esac
done

command -v adb >/dev/null 2>&1 || { echo "[maestro-android] 未找到 adb。" >&2; exit 127; }
command -v flutter >/dev/null 2>&1 || { echo "[maestro-android] 未找到 flutter。" >&2; exit 127; }
if [[ -n "${MAESTRO_BIN:-}" && -x "$MAESTRO_BIN" ]]; then
  :
elif command -v maestro >/dev/null 2>&1; then
  MAESTRO_BIN="$(command -v maestro)"
elif [[ -x "$HOME/.maestro/bin/maestro" ]]; then
  # 官方安装器默认写入此目录；非交互 Bash 不一定会加载 zsh 的 PATH 配置。
  MAESTRO_BIN="$HOME/.maestro/bin/maestro"
else
  echo "[maestro-android] 未找到 Maestro CLI。" >&2
  exit 127
fi

# 未指定设备时只在恰好有一台已授权设备的情况下自动选择，避免多设备误测。
if [[ -z "$DEVICE" ]]; then
  CONNECTED_DEVICES=()
  while IFS= read -r serial; do
    [[ -n "$serial" ]] && CONNECTED_DEVICES+=("$serial")
  done < <(adb devices | awk '$2 == "device" { print $1 }')

  case "${#CONNECTED_DEVICES[@]}" in
    0)
      echo "[maestro-android] 未发现已授权 Android 设备；请连接设备并开启 USB 调试。" >&2
      exit 1
      ;;
    1)
      DEVICE="${CONNECTED_DEVICES[0]}"
      echo "[maestro-android] Using the only connected device: $DEVICE"
      ;;
    *)
      echo "[maestro-android] 检测到多台设备，请使用 --device 或 MAESTRO_ANDROID_DEVICE 指定目标。" >&2
      printf '[maestro-android] Available: %s\n' "${CONNECTED_DEVICES[@]}" >&2
      exit 2
      ;;
  esac
fi

if [[ "$(adb -s "$DEVICE" get-state 2>/dev/null)" != "device" ]]; then
  echo "[maestro-android] 设备 $DEVICE 未连接或未获得 USB 调试授权。" >&2
  exit 1
fi

if ! $NO_BUILD; then
  [[ -f "$ENV_FILE" ]] || {
    echo "[maestro-android] 未找到 $ENV_FILE；请从 .dev.env.template 创建并填写。" >&2
    exit 1
  }
  echo "[maestro-android] Building Android dev APK..."
  flutter build apk --debug --flavor dev --dart-define-from-file="$ENV_FILE"
fi

[[ -f "$APK_PATH" ]] || {
  echo "[maestro-android] 未找到 APK：$APK_PATH" >&2
  exit 1
}

echo "[maestro-android] Installing dev APK on $DEVICE..."
adb -s "$DEVICE" install -r -t "$APK_PATH"

MAESTRO_APP_ID=app.loopback.dev \
  MAESTRO_BIN="$MAESTRO_BIN" \
  MAESTRO_DEVICE_ID="$DEVICE" \
  scripts/test_maestro.sh "$FLOW_TARGET"
