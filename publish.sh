#!/bin/bash
# Publish an already-built release: GitHub release + Homebrew tap cask bump.
# Run after ./release.sh (which calls this). Safe to re-run — every step skips
# itself if it already happened, so a failed publish resumes where it stopped.
# DRY_RUN=1 prints the mutating commands instead of running them.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"
ZIP="GitPad-$VERSION.zip"
DMG="GitPad-$VERSION.dmg"
TAP="stalinzbb/homebrew-tap"

run() { if [ "${DRY_RUN:-0}" = "1" ]; then echo "DRY_RUN: $*"; else "$@"; fi; }

# --- preflight -------------------------------------------------------------
gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated (gh auth login)" >&2; exit 1; }
# the tag must describe the bytes in the zip: only a clean checkout of origin/main is publishable
git fetch -q origin main
[ -z "$(git status --porcelain)" ] || { echo "error: working tree has uncommitted changes — the tag would not describe this build" >&2; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || { echo "error: HEAD is not origin/main — merge the release prep PR and pull first" >&2; exit 1; }
[ -f "$ZIP" ] && [ -f "$DMG" ] || { echo "error: $ZIP / $DMG not found — run ./release.sh first" >&2; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.md \
    || { echo "error: CHANGELOG.md has no '## [$VERSION]' section — merge the release prep PR first" >&2; exit 1; }
spctl -a -vv GitPad.app 2>&1 | grep -q "Notarized Developer ID" \
    || { echo "error: GitPad.app is not a notarized build — run ./release.sh" >&2; exit 1; }
# the artifact must run: the bundle's own self-test is the smoke test
BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" GitPad.app/Contents/Info.plist)
[ "$BUILT" = "$VERSION" ] || { echo "error: GitPad.app is $BUILT, Info.plist says $VERSION — rebuild" >&2; exit 1; }
GitPad.app/Contents/MacOS/GitPad --selftest >/dev/null || { echo "error: the built app fails its self-test" >&2; exit 1; }

# --- release notes: the CHANGELOG section for this version + checksums -----
# Same shape as every release since 0.13.0: the section verbatim, then a
# "Verify your download" block users can compare against shasum -a 256.
NOTES=$(mktemp)
TAPDIR=$(mktemp -d)
trap 'rm -f "$NOTES"; rm -rf "$TAPDIR"' EXIT
awk "/^## \[$VERSION\]/{f=1} /^## \[/ && !/^## \[$VERSION\]/{f=0} f" CHANGELOG.md > "$NOTES"
printf '### Verify your download\n\n```\n%s\n```\n' "$(shasum -a 256 "$ZIP" "$DMG")" >> "$NOTES"

# --- GitHub release --------------------------------------------------------
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "release $TAG already exists — skipping creation"
else
    # --target pins the tag to the commit this build came from; without it gh tags
    # whatever origin/main is at publish time. A full release, not a pre-release:
    # /releases/latest and the README link follow "latest", which skips pre-releases —
    # 0.14.0 and 0.15.0 went out as pre-releases and the README kept serving 0.13.0.
    run gh release create "$TAG" "$ZIP" "$DMG" --latest --target "$(git rev-parse HEAD)" \
        --title "$TAG" --notes-file "$NOTES"
fi

# --- Homebrew tap cask -----------------------------------------------------
gh repo clone "$TAP" "$TAPDIR" -- --depth 1 --quiet
CASK="$TAPDIR/Casks/gitpad.rb"
if grep -q "version \"$VERSION\"" "$CASK"; then
    echo "cask already at $VERSION — skipping tap bump"
else
    # the cask url ends in .zip or .dmg; hash the matching local asset
    case $(grep -m1 '^  url ' "$CASK") in
        *.zip\") ASSET="$ZIP" ;;
        *.dmg\") ASSET="$DMG" ;;
        *) echo "error: can't tell which asset the cask url points at" >&2; exit 1 ;;
    esac
    SHA=$(shasum -a 256 "$ASSET" | cut -d' ' -f1)
    sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" \
              -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
    git -C "$TAPDIR" commit -aqm "gitpad $VERSION"
    run git -C "$TAPDIR" -c push.default=current push --quiet
fi

# --- verify ----------------------------------------------------------------
[ "${DRY_RUN:-0}" = "1" ] && { echo "DRY_RUN: done (nothing published)"; exit 0; }
# The in-app updater installs nothing it can't verify: GitHub's digest for the zip must
# exist and must equal the local file's.
LOCAL=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
REMOTE=$(gh api "repos/stalinzbb/GitPad/releases/tags/$TAG" \
    --jq ".assets[] | select(.name == \"$ZIP\") | .digest // empty" | sed 's/^sha256://')
[ "$REMOTE" = "$LOCAL" ] || { echo "error: $ZIP digest on GitHub ($REMOTE) != local ($LOCAL)" >&2; exit 1; }
TAGGED=$(gh api "repos/stalinzbb/GitPad/git/ref/tags/$TAG" --jq .object.sha)
[ "$TAGGED" = "$(git rev-parse HEAD)" ] \
    || echo "warning: tag $TAG is at ${TAGGED:0:7}, this build is $(git rev-parse --short HEAD) — an earlier publish tagged a different commit" >&2
echo "Published $TAG: https://github.com/stalinzbb/GitPad/releases/tag/$TAG"
echo "Tap cask at $VERSION. The in-app updater and brew pick it up within a day."
