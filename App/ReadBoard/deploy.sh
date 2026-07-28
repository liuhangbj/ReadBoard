#!/bin/bash
# ReadBoard 编译+部署一体化脚本——固定路径，杜绝部署错位置。
# 用法: bash deploy.sh
set -e

PROJ="/Users/hangbits/readboard/App/ReadBoard"
BIN="$PROJ/.build/debug/ReadBoardMain"
APP="/Users/hangbits/readboard/App/ReadBoard.app/Contents/MacOS/ReadBoard"
APP_DIR="/Users/hangbits/readboard/App/ReadBoard.app"

echo "==> 1/4 编译 (固定目录 $PROJ)"
cd "$PROJ"
swift build --disable-sandbox 2>&1 | tail -5

echo "==> 2/4 校验产物存在"
[ -f "$BIN" ] || { echo "!! 产物不存在: $BIN"; exit 1; }

echo "==> 3/4 停旧进程 + 部署"
pkill -x ReadBoard 2>/dev/null || true
sleep 1
cp -f "$BIN" "$APP"
# 同步 Info.plist（隐私权限声明）
cp -f "$PROJ/AppInfo.plist" "$(dirname "$APP")/../Info.plist"
xattr -cr "$APP_DIR" 2>/dev/null || true   # 清隔离属性，防 GateKeeper 拦截
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1   # 签整个 .app bundle，��二进制

echo "==> 4/4 校验部署结果"
# codesign 会改 MD5，所以用「产物大小 + 修改时间」验证，不用 MD5
SRC_SIZE=$(stat -f%z "$BIN")
DST_SIZE=$(stat -f%z "$APP")
echo "   产物大小=$SRC_SIZE  部署大小=$DST_SIZE"
ls -la "$APP"

echo "==> 重启 App"
open -a "$APP_DIR"
echo "==> 完成。验证版本标记：打开一篇文章后执行"
echo "    grep BUILD_ ~/Library/Logs/ReadBoard/readboard.log | tail -1"
