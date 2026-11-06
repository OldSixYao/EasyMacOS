#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sparkle-tools.sh
prepare_sparkle_tools
# 重复运行复用同一钥匙串项，不导出私钥。此账户与其他应用的更新密钥隔离。
"$sparkle_tools_root/bin/generate_keys" --account "$sparkle_key_account"
echo '请将上方公钥填入 scripts/Info.plist 的 SUPublicEDKey；私钥始终保留在本机钥匙串。'
