#!/bin/bash
set -euo pipefail
if [ "$#" -lt 1 ] || ! [[ "$1" =~ ^[0-9]+$ ]]; then
    echo '用法：./scripts/profile-performance.sh 进程编号 [输出目录] [采样秒数]' >&2
    exit 1
fi
app_pid="$1"
report_dir="${2:-$(mktemp -d "${TMPDIR:-/tmp}/EasyMacOS-profile.XXXXXX")}"
sample_seconds="${3:-10}"
if ! [[ "$sample_seconds" =~ ^[0-9]+$ ]] || [ "$sample_seconds" -lt 1 ] || [ "$sample_seconds" -gt 30 ]; then
    echo '单次采样需要一至三十秒。' >&2
    exit 1
fi
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd)"
sw_vers > "$report_dir/environment.txt"
ps -p "$app_pid" -o pid=,comm=,%cpu=,rss=,time= > "$report_dir/process-before.txt"
/usr/bin/sample "$app_pid" "$sample_seconds" 1 -file "$report_dir/stacks.txt" > "$report_dir/sample.log" 2>&1
ps -p "$app_pid" -o pid=,comm=,%cpu=,rss=,time= > "$report_dir/process-after.txt"
echo "进程采样结果：$report_dir"
