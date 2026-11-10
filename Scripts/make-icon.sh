#!/bin/bash
# Builds Resources/AppIcon.icns from the 1024x1024 master Resources/AppIcon.png.
# Produces every size macOS asks for: 16, 32, 128, 256, 512 pt at @1x and @2x.
set -euo pipefail
cd "$(dirname "$0")/.."
master="Resources/AppIcon.png"
work="$(mktemp -d)"
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset" --output Resources/AppIcon.icns
trash_dir="$work"
[ -d "$trash_dir" ] && find "$trash_dir" -type f -delete && find "$trash_dir" -type d -empty -delete
echo "Resources/AppIcon.icns"
