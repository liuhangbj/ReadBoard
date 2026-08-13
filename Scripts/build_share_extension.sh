#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:?usage: build_share_extension.sh OUTPUT_APPEX [SCHEME] [BUNDLE_ID]}"
CALLBACK_SCHEME="${2:-readboard}"
BUNDLE_ID="${3:-com.liuhangbj.readboard.share}"
SOURCE="$PROJECT_DIR/Sources/ReadBoardShareExtension/ShareViewController.swift"
INFO="$PROJECT_DIR/Packaging/ShareExtension-Info.plist"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCHS="${READBOARD_SHARE_ARCHS:-${READBOARD_ARCHS:-$(uname -m)}}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/readboard-share.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$OUTPUT/Contents/MacOS"
BINARIES=()
for arch in $ARCHS; do
    binary="$TMP_ROOT/ReadBoardShareExtension-$arch"
    xcrun --sdk macosx swiftc \
        -parse-as-library -emit-executable -O \
        -target "$arch-apple-macos14.0" \
        -sdk "$SDK" \
        -Xlinker -e -Xlinker _NSExtensionMain \
        "$SOURCE" -o "$binary"
    BINARIES+=("$binary")
done
if [ "${#BINARIES[@]}" -eq 1 ]; then
    cp -p "${BINARIES[0]}" "$OUTPUT/Contents/MacOS/ReadBoardShareExtension"
else
    lipo -create "${BINARIES[@]}" -output "$OUTPUT/Contents/MacOS/ReadBoardShareExtension"
fi
cp -p "$INFO" "$OUTPUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$OUTPUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :ReadBoardCallbackScheme $CALLBACK_SCHEME" "$OUTPUT/Contents/Info.plist"
if [ -n "${READBOARD_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${READBOARD_VERSION#v}" "$OUTPUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${READBOARD_BUILD_NUMBER:-1}" "$OUTPUT/Contents/Info.plist"
fi
