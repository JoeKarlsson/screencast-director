#!/usr/bin/env bash
# Tag the version in VERSION and publish a GitHub release with the built app attached.
#
#   macos/release.sh          # needs a clean main that matches origin, and a CHANGELOG section for VERSION
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=sd-notary macos/release.sh
#
# Release notes come from that version's section of CHANGELOG.md, plus the zip's SHA-256. With
# DEVELOPER_ID set, build.sh signs with it; with NOTARY_PROFILE also set (a keychain profile from
# `xcrun notarytool store-credentials`), the app is notarized and stapled before zipping. Without
# them the app is signed with the local identity, so on another Mac it needs Open Anyway the first time.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
TAG="v$VERSION"
die() { echo "release: $*" >&2; exit 1; }

[[ "$(git branch --show-current)" == main ]] || die "not on main"
[[ -z "$(git status --porcelain)" ]] || die "uncommitted changes"
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main doesn't match origin/main; pull or push first"
# A tag that exists only locally is left over from a run that failed to push; reuse it.
gh release view "$TAG" >/dev/null 2>&1 && die "$TAG is already released; bump VERSION"

# The lines under "## <version>" up to the next "## " heading.
NOTES="$(awk -v v="$VERSION" '/^## / { if (found) exit; if (index($0, "## " v) == 1) { found = 1; next } } found' CHANGELOG.md)"
[[ -n "${NOTES//[[:space:]]/}" ]] || die "CHANGELOG.md has no section for $VERSION"

[[ -n "${NOTARY_PROFILE:-}" && -z "${DEVELOPER_ID:-}" ]] && die "NOTARY_PROFILE needs DEVELOPER_ID (only a Developer ID build can be notarized)"
macos/build.sh
APP="dist/Screencast Director.app"
ZIP="dist/Screencast-Director-$VERSION.zip"
rm -f "$ZIP"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  # notarytool takes a zip; staple the ticket to the app, then zip it again for the release.
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$ZIP"
fi
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
NOTES="$NOTES

SHA-256 of $(basename "$ZIP"): \`$SHA\`"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "Screencast Director $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" --title "Screencast Director $VERSION" --notes "$NOTES"
echo "Released $TAG with $ZIP"
