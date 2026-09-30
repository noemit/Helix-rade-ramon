#!/bin/bash
# Builds a signed (and, if credentials exist, notarized + stapled) release of Faulix.
#
#   scripts/release.sh               # build, sign, notarize, staple, zip
#   NOTARIZE=0 scripts/release.sh    # build and sign only
#
# Notarization uses a keychain profile created once with:
#   xcrun notarytool store-credentials faulix-notary --apple-id <apple id> --team-id CT5KSA99W8
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-faulix-notary}"
DERIVED="build/Release"
DIST="dist"
APP="$DERIVED/Build/Products/Release/Faulix.app"

xcodegen generate >/dev/null
rm -rf "$DERIVED" "$DIST"
mkdir -p "$DIST"

echo "==> Building Release"
xcodebuild -project NotHelix.xcodeproj -scheme NotHelix -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath "$DERIVED" build | grep -E "error:|warning: .*sign|BUILD" || true
[ -d "$APP" ] || { echo "Build failed"; exit 1; }

VERSION=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)
BUILD=$(defaults read "$PWD/$APP/Contents/Info" CFBundleVersion)
ZIP="$DIST/Faulix-$VERSION-$BUILD.zip"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|flags|Timestamp"

ditto -c -k --keepParent "$APP" "$ZIP"

if [ "${NOTARIZE:-1}" = "1" ]; then
  echo "==> Notarizing ($PROFILE)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo "==> $ZIP"
