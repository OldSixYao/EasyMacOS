#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_path="${1:-$PWD/dist/EasyMacOS.app}"
signing_identity="${SIGNING_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
if [ -z "$signing_identity" ]; then
    signing_identity="$(cat "$HOME/Library/Application Support/EasyMacOS/Signing/identity.sha1")"
fi
if [ "$signing_identity" = '-' ]; then
    echo '无法验证临时签名的身份稳定性。' >&2
    exit 1
fi
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/easymacos-signing-check.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

codesign --verify --deep --strict "$app_path"
original_requirement="$(codesign -d -r- "$app_path" 2>&1 | sed -n 's/^designated => //p')"
case "$original_requirement" in
    *certificate*) ;;
    *) echo '应用没有基于证书的固定指定要求。' >&2; exit 1 ;;
esac
ditto "$app_path" "$temporary_directory/Changed.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName 签名稳定性检查' "$temporary_directory/Changed.app/Contents/Info.plist"
codesign --force --timestamp=none --sign "$signing_identity" "$temporary_directory/Changed.app"
changed_requirement="$(codesign -d -r- "$temporary_directory/Changed.app" 2>&1 | sed -n 's/^designated => //p')"
original_hash="$(codesign -dv --verbose=4 "$app_path" 2>&1 | sed -n 's/^CDHash=//p')"
changed_hash="$(codesign -dv --verbose=4 "$temporary_directory/Changed.app" 2>&1 | sed -n 's/^CDHash=//p')"
if [ -z "$original_hash" ] || [ -z "$changed_hash" ] || [ "$original_requirement" != "$changed_requirement" ] || [ "$original_hash" = "$changed_hash" ]; then
    echo '内容变化后的签名身份不满足稳定性要求。' >&2
    exit 1
fi
codesign --verify --deep --strict -R "=$original_requirement" "$temporary_directory/Changed.app"
echo '通过：内容哈希已经改变，指定要求保持相同；新副本通过原应用的签名身份校验。'
echo '该检查验证身份稳定性，不会修改系统隐私权限，也不能代替首次授权。'
