#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your Developer ID Application signing identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a stored notarytool keychain profile}"
# Example: xcrun notarytool store-credentials EasyMacOS-Notary --apple-id … --team-id …
./scripts/build.sh
app_path="$PWD/dist/EasyMacOS.app"
codesign --force --options runtime --timestamp --entitlements Resources/FinderExtension.entitlements --sign "$DEVELOPER_ID_APPLICATION" "$app_path/Contents/PlugIns/FinderExtension.appex"
codesign --force --options runtime --timestamp --entitlements Resources/PasteMan.entitlements --sign "$DEVELOPER_ID_APPLICATION" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
ditto -c -k --keepParent "$app_path" "$PWD/dist/EasyMacOS-notarization.zip"
xcrun notarytool submit "$PWD/dist/EasyMacOS-notarization.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
# 必须在公证票据附加完毕后压缩和签名，之后不再修改更新包。
./scripts/package-update.sh "$app_path"
./scripts/dmg.sh "$app_path"
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$PWD/dist/EasyMacOS.dmg"
xcrun notarytool submit "$PWD/dist/EasyMacOS.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$PWD/dist/EasyMacOS.dmg"
xcrun stapler validate "$PWD/dist/EasyMacOS.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$PWD/dist/EasyMacOS.dmg"
shasum -a 256 "$PWD/dist/EasyMacOS.dmg"
