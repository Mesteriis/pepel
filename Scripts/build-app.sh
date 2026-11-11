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
# English and Russian texts; macOS picks the language the user set for the system or for PEPEL.
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$staging/Contents/Resources" >/dev/null

# Signing identity. A real certificate matters on macOS 27: the system only gives a status item
# an application identity when the app is signed with one, and menu bar managers (Hidden Bar
# 1.11+) hide every app they cannot name in their allow-list. An ad-hoc signed PEPEL therefore
# disappears whenever such a manager collapses.
#   PEPEL_SIGN_IDENTITY="Developer ID Application: …"  use this identity
#   PEPEL_SIGN_IDENTITY=-                              force ad-hoc
#   (unset)                                            first valid code-signing identity, else ad-hoc
identity="${PEPEL_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)"
fi
if [ -z "$identity" ]; then identity="-"; fi
if [ "$identity" = "-" ]; then
    echo "warning: signing ad hoc. On macOS 27 a menu bar manager such as Hidden Bar will hide PEPEL's icon." >&2
else
    echo "signing with: $identity"
fi
codesign --force --sign "$identity" "$staging/Contents/Helpers/pepel"
codesign --force --sign "$identity" "$staging"

if [ -d "$app" ]; then find "$app" -depth -delete; fi
mv "$staging" "$app"
echo "$app"
