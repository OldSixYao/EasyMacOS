#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_path="${1:-$PWD/dist/EasyMacOS.app}"
if [ ! -d "$app_path" ]; then echo "Build EasyMacOS.app first using scripts/build.sh" >&2; exit 1; fi
mkdir -p dist
staging="$(mktemp -d "${TMPDIR:-/tmp}/pasteman-dmg.XXXXXX")"
trap '/bin/rm -rf "$staging"' EXIT
ditto "$app_path" "$staging/EasyMacOS.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname EasyMacOS -srcfolder "$staging" -ov -format UDZO "$PWD/dist/EasyMacOS.dmg"
echo "DMG: $PWD/dist/EasyMacOS.dmg"
