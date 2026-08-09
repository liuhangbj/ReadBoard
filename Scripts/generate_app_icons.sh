#!/usr/bin/env bash
# 从两张 1024 x 1024 母版生成 macOS AppIcon 资源。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIGHT_SOURCE="${1:-$PROJECT_DIR/design/icons/readboard-standard-1024.png}"
DARK_SOURCE="${2:-$PROJECT_DIR/design/icons/readboard-standard-dark-1024.png}"
CATALOG_DIR="${3:-$PROJECT_DIR/Packaging/Assets.xcassets}"

for source in "$LIGHT_SOURCE" "$DARK_SOURCE"; do
    [ -f "$source" ] || { echo "!! 找不到图标母版：$source" >&2; exit 1; }
    width="$(sips -g pixelWidth "$source" | awk '/pixelWidth/ {print $2}')"
    height="$(sips -g pixelHeight "$source" | awk '/pixelHeight/ {print $2}')"
    [ "$width" = "1024" ] && [ "$height" = "1024" ] || {
        echo "!! 图标母版必须是 1024 x 1024：$source" >&2
        exit 1
    }
done

generate_set() {
    local source="$1"
    local output="$2"
    mkdir -p "$output"
    while read -r filename pixels; do
        sips --resampleHeightWidth "$pixels" "$pixels" "$source" \
            --out "$output/$filename" >/dev/null
    done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES
}

generate_set "$LIGHT_SOURCE" "$CATALOG_DIR/AppIcon.appiconset"
generate_set "$DARK_SOURCE" "$CATALOG_DIR/AppIconDark.appiconset"
echo "==> 已生成浅色和深色 AppIcon：$CATALOG_DIR"
