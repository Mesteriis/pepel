#!/bin/bash
# Renders the real views with this machine's real state into docs/screenshots/.
# No screen-recording permission is needed: the app draws its own views into PNG files and exits.
# The images show your project names and running commands; they are git-ignored on purpose.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d dist/PEPEL.app ] || Scripts/build-app.sh release
mkdir -p docs/screenshots
PEPEL_SNAPSHOT_DIR="$PWD/docs/screenshots" dist/PEPEL.app/Contents/MacOS/PEPEL
ls docs/screenshots
