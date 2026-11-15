#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v flutter >/dev/null 2>&1; then
  echo "[check] ERROR: flutter not found in PATH" >&2
  exit 1
fi

run_step() {
  local name="$1"
  shift
  echo "[check] >>> $name"
  "$@"
  echo "[check] <<< $name (ok)"
}

run_step "dart format" dart format --output=none --set-exit-if-changed lib test
run_step "flutter analyze" flutter analyze --no-fatal-infos
run_step "flutter test" flutter test --concurrency=1

# macOS 专属：其余平台（主要是 Windows 主力机）跑到这里算通过。
if [[ "$(uname -s)" == "Darwin" ]]; then
  run_step "flutter test integration_test -d macos" flutter test integration_test -d macos
  run_step "flutter build macos" flutter build macos
else
  echo "[check] skip macOS integration_test / build (host is $(uname -s))"
fi

echo "[check] All checks passed"
