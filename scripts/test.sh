#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# CLT 27's Swift Build engine omits TestingMacros from its automatic plugin search.
compiler_path="$(xcrun --find swiftc)"
testing_plugin="$(dirname "$(dirname "$compiler_path")")/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$testing_plugin" ]; then
    swift test -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin"
else
    swift test
fi
