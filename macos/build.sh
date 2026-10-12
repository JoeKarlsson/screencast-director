#!/usr/bin/env bash
# Build dist/Screencast Director.app: the app, the director CLI, and (if built) a bundled
# whisper-cli. Signed with $DEVELOPER_ID when set (a "Developer ID Application: ..." identity,
# for notarized releases), else a local identity if there is one, else ad-hoc. Without a
# Developer ID, other Macs need Open Anyway the first time.
#
#   macos/build.sh            # → dist/Screencast Director.app
#   macos/build.sh --install  # ...and copy it to /Applications
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" macos/build.sh
set -euo pipefail

INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP="$ROOT/dist/Screencast Director.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/ScreencastDirector" "$BIN/director" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/edit-prompt.md Resources/ScreencastDirector.icns "$APP/Contents/Resources/"
[[ -f Resources/tour.mp4 ]] && cp Resources/tour.mp4 "$APP/Contents/Resources/"
# Without a bundled whisper-cli the app falls back to Homebrew's (brew install whisper-cpp).
[[ -x .whisper/whisper-cli ]] && cp .whisper/whisper-cli "$APP/Contents/Helpers/"

VERSION="$(cat "$ROOT/VERSION")"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
# Build number: the commit count, so every build from a newer commit sorts higher.
plutil -replace CFBundleVersion -string "$(git -C "$ROOT" rev-list --count HEAD)" "$APP/Contents/Info.plist"

# A fixed identity keeps Screen Recording, Input Monitoring, mic and camera permissions across
# rebuilds; macOS keys them to the signature, and ad-hoc changes it every build. Followspot's
# identity works too (macOS goes by the certificate, not its name).
IDENTITY="-"
SIGN_FLAGS=(--force --options runtime)
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  IDENTITY="$DEVELOPER_ID"
  # Notarization needs a secure timestamp.
  SIGN_FLAGS+=(--timestamp)
else
  for name in "Screencast Director Local Signing" "Followspot Local Signing"; do
    if security find-certificate -c "$name" >/dev/null 2>&1; then
      IDENTITY="$name"
      break
    fi
  done
fi
# Inside out: helpers first, then the app that contains them.
for helper in "$APP/Contents/MacOS/director" "$APP/Contents/Helpers/"*; do
  [[ -e "$helper" ]] && codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$helper"
done
codesign "${SIGN_FLAGS[@]}" --entitlements Resources/ScreencastDirector.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built dist/Screencast Director.app ($VERSION, signed: $IDENTITY)"

if [[ "$INSTALL" == 1 ]]; then
  if pgrep -xq ScreencastDirector; then
    osascript -e 'tell application "Screencast Director" to quit' 2>/dev/null || true
    for _ in $(seq 1 50); do pgrep -xq ScreencastDirector || break; sleep 0.1; done
  fi
  rm -rf "/Applications/Screencast Director.app"
  ditto "$APP" "/Applications/Screencast Director.app"
  echo "Installed /Applications/Screencast Director.app"
fi
