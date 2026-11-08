#!/bin/bash
# design/icon_shanhai.py → design/appIcon.png → Shanhai/Resources/AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/.venv/bin/python design/icon_shanhai.py design/appIcon.png
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"; mkdir -p "$ICONSET"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x 128:icon_128x128 \
            256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
    sips -z "${spec%%:*}" "${spec%%:*}" design/appIcon.png --out "$ICONSET/${spec##*:}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Shanhai/Resources/AppIcon.icns
echo "Wrote Shanhai/Resources/AppIcon.icns"
