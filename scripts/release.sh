#!/usr/bin/env bash
#
# Cut a new release of TantivySwift.
#
# Builds the multi-platform xcframework, publishes it as a GitHub Release asset,
# and pins Package.swift to that asset's URL + SHA256 so SwiftPM downloads and
# checksum-verifies it (no committed binary, no Git LFS).
#
# Usage:
#   scripts/release.sh <version> [--yes] [--allow-branch]
#   e.g.  scripts/release.sh 0.1.1
#
#   --yes           skip the confirmation prompt
#   --allow-branch  permit releasing from a branch other than main
#
# Requirements (run on macOS, from a clean checkout):
#   * full Xcode (for scripts/build-xcframework.sh) — if your active developer
#     dir is the Command Line Tools, prefix with
#     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
#   * a Swift toolchain (for `swift package compute-checksum`)
#   * an authenticated GitHub CLI (`gh auth login`)
#
# The tag and the release asset are created together (via `gh release create`),
# so there is no window where Package.swift points at a URL that 404s.
#
# The test suite runs against the freshly built xcframework before anything is
# committed or published: with artifacts/ present, Package.swift resolves the
# local binary target, so the tests exercise the exact artifact that will ship —
# including its bundled ctantivy.h, which is where an ABI break would hide.

set -euo pipefail
cd "$(dirname "$0")/.."

REPO="carbon/TantivySwift"            # owner/repo — must match Package.swift's URL
ASSET="CTantivy.xcframework.zip"
XCF="artifacts/CTantivy.xcframework"

# --- args -------------------------------------------------------------------
VERSION="${1:-}"
shift || true
ASSUME_YES=0
ALLOW_BRANCH=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes)          ASSUME_YES=1 ;;
    --allow-branch) ALLOW_BRANCH=1 ;;
    *) echo "error: unknown option '$1'" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$VERSION" ]; then
  echo "usage: scripts/release.sh <version> [--yes] [--allow-branch]   (e.g. 0.1.1)" >&2
  exit 2
fi
if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$'; then
  echo "error: '$VERSION' is not a semantic version (e.g. 0.1.1)" >&2
  exit 2
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"

# --- preflight --------------------------------------------------------------
command -v gh >/dev/null 2>&1 || { echo "error: gh (GitHub CLI) not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated (gh auth login)." >&2; exit 1; }
xcodebuild -version >/dev/null 2>&1 || {
  echo "error: full Xcode required. Retry with:" >&2
  echo "       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer $0 $VERSION" >&2
  exit 1
}
if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty — commit or stash before releasing." >&2
  exit 1
fi
# Releasing off main is a hard error, not a warning. A tag cut from a feature
# branch that is later squash-merged points at a commit reachable only from the
# deleted branch: `git describe` breaks and the release cannot be found from
# main's history.
if [ "$BRANCH" != "main" ] && [ "$ALLOW_BRANCH" -ne 1 ]; then
  echo "error: refusing to release from '$BRANCH' — expected 'main'." >&2
  echo "       merge first, or pass --allow-branch if you are certain." >&2
  exit 1
fi
if [ "$BRANCH" != "main" ]; then
  echo "warning: releasing from '$BRANCH', not 'main' (--allow-branch)."
fi
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null 2>&1 \
   || git ls-remote --exit-code --tags origin "$VERSION" >/dev/null 2>&1; then
  echo "error: tag '$VERSION' already exists (locally or on origin)." >&2
  exit 1
fi

echo "==> Release plan"
echo "    version : $VERSION"
echo "    branch  : $BRANCH"
echo "    asset   : $ASSET"
echo "    url     : $URL"
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Proceed? [y/N] " ans
  case "$ans" in [yY]|[yY][eE][sS]) ;; *) echo "aborted."; exit 0 ;; esac
fi

# --- build + package --------------------------------------------------------
echo "==> Building xcframework (scripts/build-xcframework.sh)"
scripts/build-xcframework.sh

# --- verify before publishing -----------------------------------------------
# artifacts/ now exists, so Package.swift is in local-binary mode and this runs
# against the artifact itself rather than a host build.
echo "==> Running tests against the built xcframework"
swift test

echo "==> Zipping $XCF -> $ASSET"
rm -f "$ASSET"
# zip -X excludes macOS metadata, so the archive has no __MACOSX / ._ AppleDouble
# cruft. Safe for a static-library xcframework (no symlinks to preserve). cd into
# the parent so the archive holds CTantivy.xcframework at its root.
( cd "$(dirname "$XCF")" && zip -qr -X "$OLDPWD/$ASSET" "$(basename "$XCF")" )

echo "==> Computing checksum"
CHECKSUM="$(swift package compute-checksum "$ASSET")"
echo "    sha256 = $CHECKSUM"

# --- pin Package.swift ------------------------------------------------------
echo "==> Pinning Package.swift"
perl -pi -e "s|^let release\b.*|let release  = \"$VERSION\"|"   Package.swift
perl -pi -e "s|^let checksum\b.*|let checksum = \"$CHECKSUM\"|" Package.swift
grep -q "let release  = \"$VERSION\"" Package.swift \
  && grep -q "let checksum = \"$CHECKSUM\"" Package.swift \
  || { echo "error: failed to patch Package.swift (check the 'let release'/'let checksum' lines)." >&2; exit 1; }
swift package dump-package >/dev/null   # manifest still parses?

# --- commit, push, publish (tag + asset together) ---------------------------
echo "==> Committing and pushing $BRANCH"
git commit -am "Release $VERSION"
git push origin "$BRANCH"
TARGET_SHA="$(git rev-parse HEAD)"

echo "==> Creating GitHub release $VERSION (tag + asset)"
gh release create "$VERSION" "$ASSET" \
  --target "$TARGET_SHA" \
  --title "$VERSION" \
  --notes "tantivy 0.26.1 Swift bindings. The prebuilt \`CTantivy.xcframework\` is attached as an asset; SwiftPM downloads and checksum-verifies it on resolve (no Git LFS required)."

git fetch --tags origin >/dev/null 2>&1 || true
rm -f "$ASSET"

# Leaving artifacts/ behind would silently shadow later work: Package.swift
# prefers a local xcframework over everything, so the next `swift test` in this
# checkout would exercise the *released* binary instead of the working source.
# Removing it falls back to downloading the release just published.
rm -rf "$(dirname "$XCF")"

echo
echo "==> Released $VERSION"
echo "    Consumers: .package(url: \"https://github.com/$REPO.git\", from: \"$VERSION\")"
