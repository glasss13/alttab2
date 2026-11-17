#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh
target="/Applications/AltTab2.app"
if [ -d "$target" ]; then
  identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")
  if [ "$identifier" != 'local.alttab2.app' ]; then
    printf '%s\n' 'Refusing to replace an unrelated application.' >&2
    exit 1
  fi
  "$target/Contents/MacOS/AltTab2" --quit >/dev/null 2>&1 || true
fi
ditto build/AltTab2.app "$target"
printf '%s\n' "Installed $target. Open it to start. Run only one Cmd+Tab replacement at a time."
