#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUNDLE_ID="top.loop-back"
APP_PATH="build/ios/iphonesimulator/Runner.app"
# 编译期环境变量统一从 .dev.env 读取（API 地址、Supabase、Google 等）
ENV_FILE=".dev.env"

DEVICE=""
NO_BUILD=false
AUTO_BOOT=false

usage() {
  cat <<'EOF'
Usage: scripts/run_simulator.sh [OPTIONS]

Build, install, and launch the app on an iOS simulator.

Options:
  --device <UDID|name>  Target simulator (default: first booted device)
  --boot                Auto-boot the device if not running
  --no-build            Skip build, install existing artifact
  -h, --help            Show this help

构建期环境变量从 .dev.env 读取（--dart-define-from-file）。
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --boot) AUTO_BOOT=true; shift ;;
    --no-build) NO_BUILD=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# --- 确定目标模拟器 ---
resolve_udid() {
  if [[ -n "$DEVICE" ]]; then
    # 尝试按 UDID 匹配
    if xcrun simctl list devices | grep -q "$DEVICE"; then
      # 如果输入像 UDID（包含连字符且长度 >= 36）直接用
      if [[ ${#DEVICE} -ge 36 && "$DEVICE" == *-* ]]; then
        echo "$DEVICE"
        return
      fi
      # 否则按名称查找 UDID
      local udid
      udid=$(xcrun simctl list devices available | grep "$DEVICE" | head -1 | sed -E 's/.*\(([A-F0-9-]{36})\).*/\1/')
      if [[ -n "$udid" ]]; then
        echo "$udid"
        return
      fi
    fi
    echo "Error: device '$DEVICE' not found" >&2
    exit 1
  fi

  # 默认取第一个已 Booted 的模拟器
  local booted
  booted=$(xcrun simctl list devices booted | grep -E '\(Booted\)' | head -1 | sed -E 's/.*\(([A-F0-9-]{36})\).*/\1/')
  if [[ -n "$booted" ]]; then
    echo "$booted"
    return
  fi

  echo "Error: no booted simulator found. Use --device <name> --boot to start one." >&2
  exit 1
}

UDID=$(resolve_udid)

# --- 确保模拟器已启动 ---
is_booted() {
  xcrun simctl list devices | grep "$UDID" | grep -q "(Booted)"
}

if ! is_booted; then
  if $AUTO_BOOT; then
    echo "🔄 Booting simulator $UDID ..."
    xcrun simctl boot "$UDID"
    open -a Simulator
    sleep 2
  else
    echo "Error: simulator $UDID is not booted. Use --boot to start it." >&2
    exit 1
  fi
fi

DEVICE_NAME=$(xcrun simctl list devices | grep "$UDID" | sed -E 's/^[[:space:]]*//' | sed -E 's/\s*\(.*//')
echo "📱 Target: $DEVICE_NAME ($UDID)"

# --- 构建 ---
if ! $NO_BUILD; then
  [[ -f "$ENV_FILE" ]] || { echo "Error: $ENV_FILE not found. Copy .dev.env.template to $ENV_FILE and fill in values." >&2; exit 1; }
  echo "🔨 Building for simulator (env: $ENV_FILE) ..."
  flutter build ios --simulator --dart-define-from-file="$ENV_FILE"
else
  if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: $APP_PATH not found. Run without --no-build first." >&2
    exit 1
  fi
  echo "⏭️  Skipping build, using existing artifact"
fi

# --- 安装并启动 ---
echo "📦 Installing ..."
xcrun simctl install "$UDID" "$APP_PATH"

echo "🚀 Launching ..."
xcrun simctl launch "$UDID" "$BUNDLE_ID"

echo "✅ Done"
