#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
report_dir="${1:-$(mktemp -d "${TMPDIR:-/tmp}/EasyMacOS-long-benchmark.XXXXXX")}"
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd)"
sw_vers > "$report_dir/environment.txt"
xcrun swift --version >> "$report_dir/environment.txt" 2>&1
plutil -extract CFBundleShortVersionString raw scripts/Info.plist > "$report_dir/version.txt"
# 先构建，后逐场景启动独立进程；编译与测量互不重叠。
./scripts/test.sh -c release --filter '^$' > "$report_dir/build.log" 2>&1
for scenario in frames match stitch stitchFresh preview export; do
    EASYMACOS_LONG_BENCHMARK_OUTPUT="$report_dir" EASYMACOS_LONG_BENCHMARK_CASE="$scenario" \
        ./scripts/test.sh -c release --skip-build --filter LongScreenshotBenchmarks \
        > "$report_dir/$scenario.log" 2>&1
    echo "测量完成：$scenario"
done
echo "长截屏性能报告：$report_dir"
