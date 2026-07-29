#!/bin/bash
# ReadBoard 编译+部署一体化脚本——固定路径，杜绝部署错位置。
# 用法: bash deploy.sh（默认 Release）；调试时 bash deploy.sh --debug
set -e

PROJ="/Users/hangbits/readboard/App/ReadBoard"
CONFIG="release"
if [ "${1:-}" = "--debug" ]; then CONFIG="debug"; fi
BIN="$PROJ/.build/$CONFIG/ReadBoardMain"
APP="/Users/hangbits/readboard/App/ReadBoard.app/Contents/MacOS/ReadBoard"
APP_DIR="/Users/hangbits/readboard/App/ReadBoard.app"

echo "==> 1/5 编译 $CONFIG (固定目录 $PROJ)"
cd "$PROJ"
swift build -c "$CONFIG" --disable-sandbox 2>&1 | tail -5

echo "==> 2/5 校验产物存在"
[ -f "$BIN" ] || { echo "!! 产物不存在: $BIN"; exit 1; }
RESOURCE_BUNDLE="$PROJ/.build/$CONFIG/ReadBoard_ReadBoard.bundle/Resources"
[ -d "$RESOURCE_BUNDLE" ] || { echo "!! 资源包不存在: $RESOURCE_BUNDLE"; exit 1; }

echo "==> 3/5 停旧进程 + 部署二进制"
pkill -x ReadBoard 2>/dev/null || true
sleep 1
cp -f "$BIN" "$APP"
# 同步 Info.plist（隐私权限声明）
cp -f "$PROJ/AppInfo.plist" "$(dirname "$APP")/../Info.plist"

echo "==> 4/5 部署运行资源"
mkdir -p "$APP_DIR/Contents/Resources"
# SwiftPM 把 engine/migrations 放进独立 resource bundle；部署到标准 App Resources。
# ditto 合并目录，不删除现有 AppIcon.icns / Assets.car。
ditto "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources"
[ -f "$APP_DIR/Contents/Resources/migrations/020_initial_schema.sql" ] \
    || { echo "!! 迁移资源未部署"; exit 1; }
[ -f "$APP_DIR/Contents/Resources/engine/fetch_engine.js" ] \
    || { echo "!! 全文引擎未部署"; exit 1; }
xattr -cr "$APP_DIR" 2>/dev/null || true   # 清隔离属性，防 GateKeeper 拦截
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1   # 签整个 .app bundle，含二进制

echo "==> 5/5 校验部署结果"
# codesign 会改 MD5，所以用「产物大小 + 修改时间」验证，不用 MD5
SRC_SIZE=$(stat -f%z "$BIN")
DST_SIZE=$(stat -f%z "$APP")
echo "   产物大小=$SRC_SIZE  部署大小=$DST_SIZE"
ls -la "$APP"

echo "==> 重启 App"
open -a "$APP_DIR"
echo "==> 完成。验证版本标记：打开一篇文章后执行"
echo "    grep BUILD_ ~/Library/Logs/ReadBoard/readboard.log | tail -1"
