#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Some Command Line Tools releases omit automatic Swift Testing macro discovery.
# Load the toolchain's own plugin explicitly when it is present.
task_swiftc="$(xcrun --find swiftc)"
task_plugin="${task_swiftc:h:h}/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$task_plugin" ]]; then
    swift test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$task_plugin" "$@"
else
    swift test --disable-xctest "$@"
fi
