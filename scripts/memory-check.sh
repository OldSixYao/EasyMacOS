#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Reports remain outside the source tree unless an explicit directory is supplied.
report_dir="${1:-$(mktemp -d "${TMPDIR:-/tmp}/EasyMacOS-memory.XXXXXX")}"
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd)"
sw_vers > "$report_dir/environment.txt"
xcrun swift --version >> "$report_dir/environment.txt" 2>&1
plutil -extract CFBundleShortVersionString raw scripts/Info.plist > "$report_dir/version.txt"
echo "验证输出目录：$report_dir"
# Only this serialized suite runs: unrelated tests must not distort the memory samples.
PASTEMAN_MEMORY_TESTS=1 PASTEMAN_MEMORY_OUTPUT="$report_dir" \
    ./scripts/test.sh --filter MemoryLifecycleTests 2>&1 | tee "$report_dir/test.log"
echo "对象释放及内存趋势验证通过，采样结果：$report_dir/samples.csv"
