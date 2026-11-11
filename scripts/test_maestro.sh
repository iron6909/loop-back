#!/usr/bin/env bash
# Maestro UI 烟测：要求目标 App 已安装在已启动的 Android 模拟器、iOS 模拟器或真机上。
# 不在此脚本中构建或启动设备，避免自动化测试意外占用本地开发设备。
#
# 用法：
#   MAESTRO_APP_ID=app.loopback.dev scripts/test_maestro.sh
#   MAESTRO_APP_ID=top.loop-back.dev scripts/test_maestro.sh maestro/smoke/first_launch.yaml
#   MAESTRO_APP_ID=app.loopback.dev MAESTRO_DEVICE_ID=<设备序列号> scripts/test_maestro.sh maestro/study

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -n "${MAESTRO_BIN:-}" && -x "$MAESTRO_BIN" ]]; then
  :
elif command -v maestro >/dev/null 2>&1; then
  MAESTRO_BIN="$(command -v maestro)"
elif [[ -x "$HOME/.maestro/bin/maestro" ]]; then
  # 官方安装器默认写入此目录；非交互 Bash 不一定会加载 zsh 的 PATH 配置。
  MAESTRO_BIN="$HOME/.maestro/bin/maestro"
else
  echo "[maestro] 未找到 Maestro CLI。请先安装：curl -fsSL https://get.maestro.mobile.dev | bash" >&2
  exit 127
fi

if [[ -z "${MAESTRO_APP_ID:-}" ]]; then
  echo "[maestro] 请设置 MAESTRO_APP_ID，例如 Android 开发包为 app.loopback.dev。" >&2
  exit 2
fi

FLOW_TARGET="${1:-maestro/smoke}"
if [[ ! -e "$FLOW_TARGET" ]]; then
  echo "[maestro] Flow 不存在：$FLOW_TARGET" >&2
  exit 2
fi

echo "[maestro] Running $FLOW_TARGET for $MAESTRO_APP_ID..."
MAESTRO_COMMAND=("$MAESTRO_BIN")
if [[ -n "${MAESTRO_DEVICE_ID:-}" ]]; then
  MAESTRO_COMMAND+=(--device "$MAESTRO_DEVICE_ID")
fi
MAESTRO_COMMAND+=(test -e "APP_ID=$MAESTRO_APP_ID" "$FLOW_TARGET")
"${MAESTRO_COMMAND[@]}"
