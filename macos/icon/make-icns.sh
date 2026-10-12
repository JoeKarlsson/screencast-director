#!/usr/bin/env bash
# Rebuild macos/Resources/ScreencastDirector.icns from the drawing in make-icon.swift,
# or from a PNG you pass in (1024x1024).
#
#   macos/icon/make-icns.sh [icon-1024.png]
set -euo pipefail

cd "$(dirname "$0")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SRC="${1:-}"
if [[ -z "$SRC" ]]; then
  SRC="$WORK/icon.png"
  swift make-icon.swift "$SRC"
fi

SET="$WORK/ScreencastDirector.iconset"
mkdir "$SET"
for px in 16 32 128 256 512; do
  sips -z "$px" "$px" "$SRC" --out "$SET/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) "$SRC" --out "$SET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o ../Resources/ScreencastDirector.icns
echo "Wrote macos/Resources/ScreencastDirector.icns"
