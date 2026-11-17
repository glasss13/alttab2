#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app="$PWD/build/AltTab2.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/AltTab2 "$app/Contents/MacOS/AltTab2"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY.md "$app/Contents/Resources/THIRD_PARTY.md"
codesign --force --sign "${ALTTAB2_SIGN_IDENTITY:--}" --identifier local.alttab2.app \
  --requirements '=designated => identifier "local.alttab2.app"' "$app"
printf '%s\n' "$app"
