#!/bin/bash
# Builds a signed (and, if credentials exist, notarized + stapled) release of Faulix.
#
#   scripts/release.sh               # build, sign, notarize, staple → dist/Faulix-<v>.dmg and .zip
#   NOTARIZE=0 scripts/release.sh    # build and sign only
#
# The .dmg is what users download: open it and drag Faulix onto the Applications shortcut.
#
# Notarization uses APPLE_ID / APPLE_PASSWORD (app-specific) / APPLE_TEAM_ID from the environment if set,
# otherwise a keychain profile created once with:
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
DMG="$DIST/Faulix-$VERSION.dmg"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|flags|Timestamp"

ditto -c -k --keepParent "$APP" "$ZIP"

if [ "${NOTARIZE:-1}" = "1" ]; then
  if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
    echo "==> Notarizing (APPLE_ID from environment)"
    AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID")
  else
    echo "==> Notarizing (keychain profile $PROFILE)"
    AUTH=(--keychain-profile "$PROFILE")
  fi
  xcrun notarytool submit "$ZIP" "${AUTH[@]}" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo "==> Building disk image"
STAGE="$DERIVED/dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Faulix.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Faulix $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"

if [ "${NOTARIZE:-1}" = "1" ]; then
  echo "==> Notarizing disk image"
  xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

echo "==> $DMG"
echo "==> $ZIP"
