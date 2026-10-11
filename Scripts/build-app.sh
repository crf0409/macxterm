#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/prepare-dependencies.sh
./Scripts/build-app-icon.sh
configuration="${CONFIGURATION:-debug}"
build_options=(--build-system native --configuration "$configuration")
# CLT 27 lacks the SwiftUI State macro plugin; its included 26.5 SDK works.
if [[ "$(xcode-select -p)" == *CommandLineTools* ]] && [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  build_options+=(--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
fi
swift build "${build_options[@]}" --product MacXTerm
bin_path="$(swift build "${build_options[@]}" --show-bin-path)"
app_path="$PWD/.build/artifacts/MacXTerm.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
# Replace the inode instead of overwriting the executable of a running preview.
cp "$bin_path/MacXTerm" "$app_path/Contents/MacOS/MacXTerm.new"
mv -f "$app_path/Contents/MacOS/MacXTerm.new" "$app_path/Contents/MacOS/MacXTerm"
for resource in "$bin_path"/*.bundle; do
  [[ -d "$resource" ]] && ditto "$resource" "$app_path/Contents/Resources/$(basename "$resource")"
done
cp Sources/MacXTermApp/Resources/PrivacyInfo.xcprivacy "$app_path/Contents/Resources/"
cp Sources/MacXTermApp/Resources/ThirdPartyNotices.txt "$app_path/Contents/Resources/"
cp Sources/MacXTermApp/Resources/AppIcon.icns "$app_path/Contents/Resources/"
python3 - "$app_path" <<'PY'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
with open('Config/Info.plist','rb') as f: data=plistlib.load(f)
data['CFBundleIdentifier']='app.macxterm.MacXTerm'
p.write_bytes(plistlib.dumps(data))
PY
codesign --force --deep --sign - --entitlements Config/MacXTerm.entitlements "$app_path"
codesign --verify --deep --strict "$app_path"
printf 'Built sandboxed application: %s\n' "$app_path"
