#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_png="${1:-Assets/Brand/macxterm-logo-v1.png}"
iconset="$PWD/.build/AppIcon.iconset"
output="$PWD/Sources/MacXTermApp/Resources/AppIcon.icns"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$source_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns --output "$output" "$iconset"
printf 'Built application icon: %s\n' "$output"
