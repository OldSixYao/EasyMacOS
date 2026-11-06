#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report_dir="${1:-$(mktemp -d "${TMPDIR:-/tmp}/EasyMacOS-benchmark.XXXXXX")}"
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd)"
sw_vers > "$report_dir/environment.txt"
xcrun swift --version >> "$report_dir/environment.txt" 2>&1
plutil -extract CFBundleShortVersionString raw scripts/Info.plist > "$report_dir/version.txt"
EASYMACOS_BENCHMARK_OUTPUT="$report_dir" ./scripts/test.sh -c release --filter OptimizationBenchmarks 2>&1 | tee "$report_dir/test.log"
echo "测量结果：$report_dir/results.json"
