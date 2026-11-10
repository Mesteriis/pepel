#!/bin/bash
# Builds PEPEL and installs it to /Applications/PEPEL.app, then starts it.
#
# Running from /Applications is not cosmetic. On macOS 27 a menu bar manager (Hidden Bar 1.11+)
# hides other apps through a system allow-list; a PEPEL started from a build folder in the home
# directory was hidden by it every time, while the same signed bundle in /Applications stays
# visible. The login item also needs the app to live here.
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/build-app.sh "${1:-release}"

target="/Applications/PEPEL.app"
osascript -e 'tell application id "dev.pepel.app" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6; do pgrep -f "PEPEL.app/Contents/MacOS/PEPEL" >/dev/null || break; sleep 0.5; done

staging="/Applications/.PEPEL.app.installing"
if [ -d "$staging" ]; then find "$staging" -depth -delete; fi
ditto dist/PEPEL.app "$staging"
codesign --verify --strict "$staging"
if [ -d "$target" ]; then find "$target" -depth -delete; fi
mv "$staging" "$target"
open "$target"
echo "installed and started $target"

if pgrep -xq "Hidden Bar"; then
    echo "Hidden Bar is running: expand it and collapse it once so it learns about the restarted PEPEL."
fi
