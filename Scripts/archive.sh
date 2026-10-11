#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  echo 'Archive requires full Xcode. Select it in Xcode Settings > Locations.' >&2
  exit 1
fi
if [[ ! -f Config/Local.xcconfig ]]; then
  echo 'Copy Config/Local.xcconfig.example to Config/Local.xcconfig and configure your registered bundle ID and team.' >&2
  exit 1
fi
xcodebuild -project MacXTerm.xcodeproj -scheme MacXTerm -configuration Release -destination 'generic/platform=macOS' -archivePath "$PWD/.build/artifacts/MacXTerm.xcarchive" archive
