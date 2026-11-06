#!/bin/bash
# 供更新签名脚本引用；工具和下载缓存只保存在忽略的构建目录中。
set -euo pipefail
sparkle_version=2.10.1
sparkle_archive_sha256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
sparkle_tools_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.build/sparkle-tools/$sparkle_version"
sparkle_key_account=EasyMacOS-Update

prepare_sparkle_tools() {
    local archive="$sparkle_tools_root/Sparkle.tar.xz"
    mkdir -p "$sparkle_tools_root"
    if [ ! -f "$archive" ]; then
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 300 \
            "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" \
            --output "$archive.download"
        mv "$archive.download" "$archive"
    fi
    if [ "$(shasum -a 256 "$archive" | awk '{print $1}')" != "$sparkle_archive_sha256" ]; then
        echo '更新工具校验失败，请移除损坏的工具缓存后重试。' >&2
        return 1
    fi
    # 每次从已校验的压缩包还原工具，避免使用被替换的缓存可执行文件。
    tar -xJf "$archive" -C "$sparkle_tools_root" bin
}
