#!/bin/bash
# 将 SwiftPM 产物组装为完整的 macOS .app。
# 本地默认 ad-hoc 签名；正式发布可通过 READBOARD_SIGN_IDENTITY 指定 Developer ID。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="release"
if [ "${1:-}" = "--debug" ]; then CONFIG="debug"; fi

OUTPUT_DIR="${READBOARD_OUTPUT_DIR:-$PROJECT_DIR/.artifacts}"
APP_PATH="$OUTPUT_DIR/ReadBoard.app"
ENGINE_DIR="$PROJECT_DIR/Sources/ReadBoard/Resources/engine"
PACKAGING_DIR="$PROJECT_DIR/Packaging"
SIGN_IDENTITY="${READBOARD_SIGN_IDENTITY:--}"
ICON_APPEARANCE="${READBOARD_ICON_APPEARANCE:-auto}"

if [ ! -d "$ENGINE_DIR/node_modules/defuddle" ]; then
    command -v npm >/dev/null 2>&1 || {
        echo "!! 缺少 npm，无法安装全文引擎依赖" >&2
        exit 1
    }
    echo "==> 安装全文引擎依赖"
    npm ci --omit=dev --prefix "$ENGINE_DIR"
fi

echo "==> 编译 ReadBoard ($CONFIG)"
cd "$PROJECT_DIR"
swift build -c "$CONFIG" --disable-sandbox
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/ReadBoardMain"
RESOURCE_BUNDLE="$BIN_DIR/ReadBoard_ReadBoard.bundle"

[ -f "$BIN" ] || { echo "!! 找不到可执行文件：$BIN" >&2; exit 1; }
[ -d "$RESOURCE_BUNDLE" ] || { echo "!! 找不到资源包：$RESOURCE_BUNDLE" >&2; exit 1; }

if [ -d "$RESOURCE_BUNDLE/migrations" ]; then
    RESOURCE_PAYLOAD="$RESOURCE_BUNDLE"
elif [ -d "$RESOURCE_BUNDLE/Resources/migrations" ]; then
    RESOURCE_PAYLOAD="$RESOURCE_BUNDLE/Resources"
else
    echo "!! 资源包中缺少 migrations" >&2
    exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/readboard-package.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
TMP_APP="$TMP_ROOT/ReadBoard.app"
mkdir -p "$TMP_APP/Contents/MacOS" "$TMP_APP/Contents/Resources"

cp -p "$BIN" "$TMP_APP/Contents/MacOS/ReadBoard"
cp -p "$PACKAGING_DIR/Info.plist" "$TMP_APP/Contents/Info.plist"
if [ -n "${READBOARD_VERSION:-}" ]; then
    VERSION="${READBOARD_VERSION#v}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
        "$TMP_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${READBOARD_BUILD_NUMBER:-1}" \
        "$TMP_APP/Contents/Info.plist"
fi
ditto "$RESOURCE_PAYLOAD" "$TMP_APP/Contents/Resources"

# macOS 的传统 icns 不会随系统外观自动切换，因此把两个版本都装入 App，
# 并在打包时把当前外观对应的版本设为主图标。可用
# READBOARD_ICON_APPEARANCE=light|dark|auto 显式控制。
if [ "$ICON_APPEARANCE" = "auto" ]; then
    if defaults read -g AppleInterfaceStyle 2>/dev/null | grep -q '^Dark$'; then
        ICON_APPEARANCE="dark"
    else
        ICON_APPEARANCE="light"
    fi
fi
case "$ICON_APPEARANCE" in
    light) PRIMARY_ICON="AppIconLight.icns" ;;
    dark) PRIMARY_ICON="AppIconDark.icns" ;;
    *) echo "!! READBOARD_ICON_APPEARANCE 只能是 auto、light 或 dark" >&2; exit 1 ;;
esac

make_icns() {
    local source="$1"
    local output="$2"
    local iconset="$TMP_ROOT/$(basename "$output" .icns).iconset"
    mkdir -p "$iconset"
    for name in \
        icon_16x16.png icon_16x16@2x.png \
        icon_32x32.png icon_32x32@2x.png \
        icon_128x128.png icon_128x128@2x.png \
        icon_256x256.png icon_256x256@2x.png \
        icon_512x512.png icon_512x512@2x.png; do
        [ -f "$source/$name" ] || { echo "!! 缺少图标资源：$source/$name" >&2; exit 1; }
        cp -p "$source/$name" "$iconset/$name"
    done
    iconutil -c icns "$iconset" -o "$output"
}

ICON_CATALOG="$PACKAGING_DIR/Assets.xcassets"
make_icns "$ICON_CATALOG/AppIcon.appiconset" \
    "$TMP_APP/Contents/Resources/AppIconLight.icns"
make_icns "$ICON_CATALOG/AppIconDark.appiconset" \
    "$TMP_APP/Contents/Resources/AppIconDark.icns"
cp -p "$TMP_APP/Contents/Resources/$PRIMARY_ICON" \
    "$TMP_APP/Contents/Resources/AppIcon.icns"

xattr -cr "$TMP_APP" 2>/dev/null || true
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$TMP_APP"
else
    codesign --force --options runtime --timestamp \
        --entitlements "$PACKAGING_DIR/ReadBoard.entitlements" \
        --sign "$SIGN_IDENTITY" "$TMP_APP"
fi
codesign --verify --deep --strict "$TMP_APP"

mkdir -p "$OUTPUT_DIR"
if [ -e "$APP_PATH" ]; then
    mv "$APP_PATH" "$TMP_ROOT/previous.app"
fi
mv "$TMP_APP" "$APP_PATH"

echo "==> App 已生成：$APP_PATH"
