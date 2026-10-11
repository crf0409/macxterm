#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for dependency in \
  Vendor/FreeRDP/lib/libfreerdp3.a \
  Vendor/FreeRDP/lib/libwinpr3.a \
  Vendor/FreeRDP/include/freerdp3/freerdp/freerdp.h \
  Vendor/FreeRDP/include/winpr3/winpr/wtypes.h; do
  if [[ ! -f "$dependency" ]]; then
    python3 Scripts/build-rdp-dependency.py
    break
  fi
done
