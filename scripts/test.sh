#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 原生窗口、快捷键与主线程计时共享进程状态，默认显式串行运行。
# Swift Testing 未收到明确选项时仍可能并行；纯逻辑专项可主动传入 --parallel。
has_execution_option=false
for argument in "$@"; do
    case "$argument" in --parallel|--no-parallel) has_execution_option=true; break ;; esac
done
if [ "$has_execution_option" = false ]; then set -- --no-parallel "$@"; fi
# CLT 27's Swift Build engine omits TestingMacros from its automatic plugin search.
compiler_path="$(xcrun --find swiftc)"
testing_plugin="$(dirname "$(dirname "$compiler_path")")/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$testing_plugin" ]; then
    swift test -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin" "$@"
else
    swift test "$@"
fi
