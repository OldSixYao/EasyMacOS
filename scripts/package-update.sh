#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sparkle-tools.sh
app_path="${1:-$PWD/dist/EasyMacOS.app}"
output_path="${2:-$PWD/dist/updates}"
prepare_sparkle_tools
codesign --verify --deep --strict "$app_path"
configured_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app_path/Contents/Info.plist")"
# 只读取已有密钥；缺少密钥或密钥不匹配时停止，不自动生成替代密钥。
keychain_public_key="$("$sparkle_tools_root/bin/generate_keys" --account "$sparkle_key_account" -p)"
if [ -z "$configured_key" ] || [ "$configured_key" != "$keychain_public_key" ]; then
    echo '更新公钥与钥匙串不匹配，不能生成可发布的更新。' >&2
    exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! [[ "$build" =~ ^[0-9]+$ ]]; then
    echo '应用版本必须为三段数字，构建号必须为数字。' >&2
    exit 1
fi
extension_info="$app_path/Contents/PlugIns/FinderExtension.appex/Contents/Info.plist"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extension_info")" != "$version" ] ||
   [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$extension_info")" != "$build" ]; then
    echo '主应用与访达扩展版本不一致，不能发布更新。' >&2
    exit 1
fi
mkdir -p "$output_path"
staging="$(mktemp -d "$output_path/.update.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
archive_name="EasyMacOS-$version.zip"
ditto -c -k --keepParent "$app_path" "$staging/$archive_name"
signature="$("$sparkle_tools_root/bin/sign_update" --account "$sparkle_key_account" -p "$staging/$archive_name")"
"$sparkle_tools_root/bin/sign_update" --account "$sparkle_key_account" --verify "$staging/$archive_name" "$signature"
python3 - "$app_path" "$staging" "$archive_name" "$signature" <<'PY'
import datetime
import email.utils
import pathlib
import plistlib
import sys
import xml.etree.ElementTree as ET

app, staging, archive_name, signature = sys.argv[1:]
with open(pathlib.Path(app) / 'Contents/Info.plist', 'rb') as source:
    info = plistlib.load(source)
version = info['CFBundleShortVersionString']
notes = []
collect = False
for line in pathlib.Path('CHANGELOG.md').read_text().splitlines():
    if line.startswith('## '):
        if collect:
            break
        collect = line.startswith(f'## {version}（')
    elif collect:
        notes.append(line)
sparkle = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', sparkle)
rss = ET.Element('rss', {'version': '2.0'})
channel = ET.SubElement(rss, 'channel')
ET.SubElement(channel, 'title').text = 'EasyMacOS'
ET.SubElement(channel, 'link').text = 'https://github.com/OldSixYao/EasyMacOS/releases'
item = ET.SubElement(channel, 'item')
ET.SubElement(item, 'title').text = f'EasyMacOS {version}'
ET.SubElement(item, 'pubDate').text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
ET.SubElement(item, f'{{{sparkle}}}version').text = info['CFBundleVersion']
ET.SubElement(item, f'{{{sparkle}}}shortVersionString').text = version
ET.SubElement(item, f'{{{sparkle}}}minimumSystemVersion').text = info['LSMinimumSystemVersion']
ET.SubElement(item, 'description', {f'{{{sparkle}}}format': 'plain-text'}).text = '\n'.join(notes).strip() or f'EasyMacOS {version}'
ET.SubElement(item, 'enclosure', {
    'url': f'https://github.com/OldSixYao/EasyMacOS/releases/download/v{version}/{archive_name}',
    'length': str((pathlib.Path(staging) / archive_name).stat().st_size),
    'type': 'application/octet-stream',
    f'{{{sparkle}}}edSignature': signature,
})
ET.indent(rss)
ET.ElementTree(rss).write(pathlib.Path(staging) / 'appcast.xml', encoding='utf-8', xml_declaration=True)
PY
mv "$staging/$archive_name" "$output_path/$archive_name"
mv "$staging/appcast.xml" "$output_path/appcast.xml"
echo "已生成并校验更新包：$output_path/$archive_name"
echo "更新清单：$output_path/appcast.xml"
echo '此脚本不上传附件。正式发行须先完成苹果开发者签名与公证。'
