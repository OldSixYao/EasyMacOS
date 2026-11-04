#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
case "$configuration" in release|debug) ;; *) echo 'CONFIGURATION must be release or debug' >&2; exit 1;; esac
swift build --build-system native -c "$configuration" --arch arm64
binary_dir="$(swift build --build-system native -c "$configuration" --arch arm64 --show-bin-path)"
app_path="$PWD/dist/EasyMacOS.app"
# Replace generated bundle only; never touch user history or preferences.
if [ -d "$app_path" ]; then /bin/rm -rf "$app_path"; fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/EasyMacOS" "$app_path/Contents/MacOS/EasyMacOS"
cp scripts/Info.plist "$app_path/Contents/Info.plist"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$app_path/Contents/Resources/"
if [ -n "${BUNDLE_ID:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$app_path/Contents/Info.plist"; fi
if [ -n "${VERSION:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app_path/Contents/Info.plist"; fi
swift scripts/make-icon.swift "$PWD/dist/AppIcon.iconset"
iconutil -c icns "$PWD/dist/AppIcon.iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
# Ad-hoc signing makes the local bundle runnable. This is not Developer ID signing or notarization.
codesign --force --sign - "$app_path"
echo "Built local, ad-hoc signed app: $app_path"
