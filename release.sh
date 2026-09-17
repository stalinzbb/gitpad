#!/bin/bash
# Build, sign (Developer ID), notarize, package, and publish GitPad (via publish.sh).
# Dev builds use ./build.sh (ad-hoc signed); this script is the production path.
#
# One-time setup (stores an app-specific password in your keychain; Claude/CI never see it):
#   xcrun notarytool store-credentials gitpad-notary --apple-id <you@apple.id> --team-id <TEAMID>
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" \
    | sed 's/.*"\(.*\)"/\1/') || true
if [ -z "${IDENTITY:-}" ]; then
    echo "error: no 'Developer ID Application' certificate in the keychain." >&2
    echo "Create one at developer.apple.com → Certificates, download, and double-click to install." >&2
    exit 1
fi

# Build only what main has. A dirty tree or a local main that's behind/ahead of origin
# would ship code no PR reviewed, under a tag that points somewhere else.
git fetch -q origin main
[ -z "$(git status --porcelain)" ] || { echo "error: working tree has uncommitted changes" >&2; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || { echo "error: HEAD is not origin/main — merge the release prep PR and pull first" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ZIP="GitPad-$VERSION.zip"

# assemble the app exactly like build.sh, then sign for real
if [ ! -f Resources/AppIcon.icns ] || [ make-icon.swift -nt Resources/AppIcon.icns ] \
   || [ Resources/AppIcon-source.png -nt Resources/AppIcon.icns ]; then
    ./make-icns.sh
fi
swift build -c release
rm -rf GitPad.app "$ZIP"
mkdir -p GitPad.app/Contents/MacOS GitPad.app/Contents/Resources
cp .build/release/GitPad GitPad.app/Contents/MacOS/
cp Info.plist GitPad.app/Contents/
cp Resources/AppIcon.icns Resources/MenuBarIcon.svg GitPad.app/Contents/Resources/
codesign --force --options runtime --timestamp --sign "$IDENTITY" GitPad.app

# notarize a temp zip, staple the app, then zip the stapled app for distribution
ditto -c -k --keepParent GitPad.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile gitpad-notary --wait
xcrun stapler staple GitPad.app
rm "$ZIP"
ditto -c -k --keepParent GitPad.app "$ZIP"

# DMG: same stapled app, drag-to-Applications layout; the DMG itself gets its own
# notarization ticket so Gatekeeper verifies it offline too
DMG="GitPad-$VERSION.dmg"
rm -rf dmg-stage "$DMG"
mkdir dmg-stage && cp -R GitPad.app dmg-stage/ && ln -s /Applications dmg-stage/Applications
hdiutil create -volname GitPad -srcfolder dmg-stage -ov -format UDZO "$DMG"
rm -rf dmg-stage
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile gitpad-notary --wait
xcrun stapler staple "$DMG"

spctl -a -vv GitPad.app
echo "Release ready: $(pwd)/$ZIP + $DMG (v$VERSION, notarized + stapled)"
shasum -a 256 "$ZIP" "$DMG"
# GitHub pre-release + tap cask. Idempotent, so a failed publish is re-run alone: ./publish.sh
./publish.sh
