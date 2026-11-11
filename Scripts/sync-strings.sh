#!/bin/bash
# Collects every localizable string the compiler sees (Text, LocalizedStringKey parameters,
# String(localized:), L(...)) and merges them into Resources/Localizable.xcstrings.
# New keys arrive untranslated; keys no longer in the code are marked stale.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
# A fresh build in the temporary folder, so every file is compiled and emits its keys.
swift build --product PEPELApp --build-path "$out/build" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$out" >/dev/null
[ -f Resources/Localizable.xcstrings ] || printf '{\n  "sourceLanguage" : "en",\n  "strings" : {},\n  "version" : "1.0"\n}\n' > Resources/Localizable.xcstrings
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata $(find "$out" -maxdepth 1 -name "*.stringsdata")
echo "$(ls $(find "$out" -maxdepth 1 -name "*.stringsdata") | wc -l | tr -d ' ') files scanned"
