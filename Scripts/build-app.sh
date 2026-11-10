#!/bin/bash
# Builds dist/PEPEL.app (menu bar app) with the `pepel` CLI inside it.
# Usage: Scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."
config="${1:-release}"

swift build -c "$config" --product PEPELApp
swift build -c "$config" --product pepel
bin="$(swift build -c "$config" --show-bin-path)"

app="dist/PEPEL.app"
staging="dist/.PEPEL.app.staging"
mkdir -p dist
# Assemble next to the destination and swap, so a failed build never leaves a half-made bundle.
if [ -d "$staging" ]; then find "$staging" -depth -delete; fi
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources" "$staging/Contents/Helpers"

cp "$bin/PEPELApp" "$staging/Contents/MacOS/PEPEL"
# The CLI lives outside MacOS/: on a case-insensitive volume "pepel" would overwrite "PEPEL".
cp "$bin/pepel" "$staging/Contents/Helpers/pepel"
cp Resources/Info.plist "$staging/Contents/Info.plist"
cp Resources/AppIcon.icns "$staging/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png Resources/MenuBarIcon@3x.png \
   Resources/Glyph.png Resources/Glyph@2x.png Resources/NotificationIcon.png "$staging/Contents/Resources/"

# Ad-hoc signature: enough for local use, notifications and the login item. Distribution to
# other Macs needs a Developer ID signature and notarisation.
codesign --force --sign - "$staging/Contents/Helpers/pepel"
codesign --force --sign - "$staging"

if [ -d "$app" ]; then find "$app" -depth -delete; fi
mv "$staging" "$app"
echo "$app"
