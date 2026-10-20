#!/bin/sh
set -eu
mkdir -p build/XGlyph.iconset
for points in 16 32 128 256 512; do
  sips -z "$points" "$points" app/Assets/XGlyph-icon.png --out "build/XGlyph.iconset/icon_${points}x${points}.png" >/dev/null
  pixels=$((points * 2))
  sips -z "$pixels" "$pixels" app/Assets/XGlyph-icon.png --out "build/XGlyph.iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns build/XGlyph.iconset -o build/AppIcon.icns
