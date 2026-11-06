#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
case "$configuration" in release|debug) ;; *) echo 'CONFIGURATION must be release or debug' >&2; exit 1;; esac
signing_identity="${SIGNING_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
if [ -z "$signing_identity" ]; then
    identity_file="$HOME/Library/Application Support/EasyMacOS/Signing/identity.sha1"
    if [ ! -f "$identity_file" ]; then
        echo '尚未配置固定签名。请先运行 ./scripts/setup-signing.sh，或设置 SIGNING_IDENTITY 为钥匙串中的代码签名身份。' >&2
        exit 1
    fi
    signing_identity="$(cat "$identity_file")"
    if ! [[ "$signing_identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        echo '本机签名配置损坏，请恢复原签名身份指纹，不能自动更换证书。' >&2
        exit 1
    fi
fi
if [ "$signing_identity" = '-' ]; then
    echo '构建需要固定证书身份，不再接受会使授权失效的临时签名。' >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | grep -Fqi -- "$signing_identity"; then
    echo '指定的代码签名身份不可用，请检查钥匙串中的证书、私钥和有效期。构建不会回退到临时签名。' >&2
    exit 1
fi
swift build --build-system native -c "$configuration" --arch arm64
binary_dir="$(swift build --build-system native -c "$configuration" --arch arm64 --show-bin-path)"
app_path="$PWD/dist/EasyMacOS.app"
# Replace generated bundle only; never touch user history or preferences.
if [ -d "$app_path" ]; then /bin/rm -rf "$app_path"; fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/EasyMacOS" "$app_path/Contents/MacOS/EasyMacOS"
cp scripts/Info.plist "$app_path/Contents/Info.plist"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$app_path/Contents/Resources/"
# 共享核心的模板资源包由包管理器生成，独立应用不能依赖构建目录。
resource_bundle="$binary_dir/EasyMacOS_FinderMenuCore.bundle"
test -d "$resource_bundle"
cp -R "$resource_bundle" "$app_path/Contents/Resources/"
framework_path="$app_path/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app_path/Contents/Frameworks"
ditto "$binary_dir/Sparkle.framework" "$framework_path"
cp .build/checkouts/Sparkle/LICENSE "$app_path/Contents/Resources/Sparkle-LICENSE.txt"
if [ -n "${BUNDLE_ID:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$app_path/Contents/Info.plist"; fi
if [ -n "${VERSION:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app_path/Contents/Info.plist"; fi
swift scripts/make-icon.swift "$PWD/dist/AppIcon.iconset"
iconutil -c icns "$PWD/dist/AppIcon.iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
# 访达扩展直接内嵌于唯一的宿主应用，由系统按需管理。
extension_path="$app_path/Contents/PlugIns/FinderExtension.appex"
mkdir -p "$extension_path/Contents/MacOS"
mkdir -p "$extension_path/Contents/Resources"
cp -R "$resource_bundle" "$extension_path/Contents/Resources/"
cp "$binary_dir/FinderExtension" "$extension_path/Contents/MacOS/FinderExtension"
cp scripts/FinderExtensionInfo.plist "$extension_path/Contents/Info.plist"
project_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
project_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' scripts/Info.plist)"
host_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $project_version" "$extension_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $project_build" "$extension_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${host_identifier}.FinderExtension" "$extension_path/Contents/Info.plist"
# 固定证书使指定要求基于签名身份，而非随构建变化的内容哈希。
sparkle_signing_flags=(--force --timestamp=none --sign "$signing_identity")
if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
    sparkle_signing_flags=(--force --options runtime --timestamp --sign "$signing_identity")
fi
codesign "${sparkle_signing_flags[@]}" "$framework_path/Versions/B/XPCServices/Installer.xpc"
codesign "${sparkle_signing_flags[@]}" --preserve-metadata=entitlements "$framework_path/Versions/B/XPCServices/Downloader.xpc"
codesign "${sparkle_signing_flags[@]}" "$framework_path/Versions/B/Autoupdate"
codesign "${sparkle_signing_flags[@]}" "$framework_path/Versions/B/Updater.app"
codesign "${sparkle_signing_flags[@]}" "$framework_path"
codesign --force --timestamp=none --sign "$signing_identity" --entitlements Resources/FinderExtension.entitlements "$extension_path"
codesign --force --timestamp=none --sign "$signing_identity" "$app_path"
codesign --verify --deep --strict "$app_path"
echo "已使用固定身份签名：$app_path"
