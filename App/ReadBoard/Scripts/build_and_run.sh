#!/bin/bash
# 构建并安装本地开发版 ReadBoard。
# 默认安装到 ~/Applications/ReadBoard.app，可通过 READBOARD_OUTPUT_DIR 覆盖。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${READBOARD_OUTPUT_DIR:-$HOME/Applications}"

pkill -x ReadBoard 2>/dev/null || true
READBOARD_OUTPUT_DIR="$OUTPUT_DIR" "$SCRIPT_DIR/package_app.sh" "$@"

APP_PATH="$OUTPUT_DIR/ReadBoard.app"
open "$APP_PATH"
echo "==> 已启动 $APP_PATH"
