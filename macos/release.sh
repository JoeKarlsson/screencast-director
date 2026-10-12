#!/usr/bin/env bash
# Tag the version in VERSION and publish a GitHub release with the built app attached.
#
#   macos/release.sh          # needs a clean main that matches origin, and a CHANGELOG section for VERSION
#
# Release notes come from that version's section of CHANGELOG.md. The app is signed with the local
# identity (see build.sh), not a Developer ID, so on another Mac it needs Open Anyway the first time.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
TAG="v$VERSION"
die() { echo "release: $*" >&2; exit 1; }

[[ "$(git branch --show-current)" == main ]] || die "not on main"
[[ -z "$(git status --porcelain)" ]] || die "uncommitted changes"
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main doesn't match origin/main; pull or push first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "$TAG already exists; bump VERSION"

# The lines under "## <version>" up to the next "## " heading.
NOTES="$(awk -v v="$VERSION" '/^## / { if (found) exit; if (index($0, "## " v) == 1) { found = 1; next } } found' CHANGELOG.md)"
[[ -n "${NOTES//[[:space:]]/}" ]] || die "CHANGELOG.md has no section for $VERSION"

macos/build.sh
ZIP="dist/Screencast-Director-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "dist/Screencast Director.app" "$ZIP"

git tag -a "$TAG" -m "Screencast Director $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" --title "Screencast Director $VERSION" --notes "$NOTES"
echo "Released $TAG with $ZIP"
