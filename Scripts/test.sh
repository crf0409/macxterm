#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/prepare-dependencies.sh
args=(--build-system native --disable-xctest --enable-swift-testing)
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  [[ ! -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]] || args+=(--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
  framework_path="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
  args+=(-Xswiftc -F -Xswiftc "$framework_path" -Xlinker -rpath -Xlinker "$framework_path")
fi
swift test "${args[@]}" "$@"
