#!/bin/sh
# release.sh: a release of Rimlight for other Macs, in dist/: a universal app (Apple silicon and Intel), signed
# with a Developer ID and the hardened runtime, notarized by Apple and stapled, in a DMG with an Applications link.
#
#   ./release.sh           needs a "Developer ID Application" identity in the keychain, and notary credentials
#                          saved as the keychain profile "rimlight-notary" (README, Releasing). Override with
#                          RIMLIGHT_SIGN_IDENTITY and RIMLIGHT_NOTARY_PROFILE.
#   ./release.sh --local   signs with this Mac's self-signed identity and skips notarizing: checks the packaging
#                          only; other Macs will refuse to open this one.
#
# The tests run first; a failure stops the release (SKIP_TESTS=1 skips them, for a packaging-only rerun).
set -e
cd "$(dirname "$0")"
LOCAL=0; [ "$1" = "--local" ] && LOCAL=1
VERSION="$(cat VERSION)"
DIST="$PWD/dist"; APP="$DIST/Rimlight.app"; DMG="$DIST/Rimlight-$VERSION.dmg"
PROFILE="${RIMLIGHT_NOTARY_PROFILE:-rimlight-notary}"
ENT="$PWD/Resources/Rimlight.entitlements"

if [ $LOCAL = 0 ]; then
  ID="${RIMLIGHT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
  [ -n "$ID" ] || { echo "release.sh: no Developer ID Application identity in the keychain (README, Releasing)"; exit 1; }
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || { echo "release.sh: no notary credentials in the keychain profile \"$PROFILE\" (README, Releasing)"; exit 1; }
  echo "signing as: $ID"
fi
git diff --quiet HEAD 2>/dev/null || echo "note: this build includes uncommitted changes"

[ "$SKIP_TESTS" = 1 ] || swift test -c release
swift build -c release --arch arm64 --arch x86_64 --product Rimlight
BIN="$(swift build -c release --arch arm64 --arch x86_64 --product Rimlight --show-bin-path)/Rimlight"
lipo "$BIN" -verify_arch arm64 && lipo "$BIN" -verify_arch x86_64

mkdir -p "$DIST"
scripts/bundle.sh "$BIN" "$APP"
if [ $LOCAL = 1 ]; then
  scripts/sign-local.sh "$APP"
else
  codesign --force --options runtime --timestamp --entitlements "$ENT" -s "$ID" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

if [ $LOCAL = 0 ]; then
  # the app first, so a copy dragged out of the DMG carries its own ticket
  ZIP="$DIST/Rimlight-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Rimlight $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"

if [ $LOCAL = 0 ]; then
  codesign --force --timestamp -s "$ID" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t exec -vv "$APP"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
fi

echo
echo "Rimlight $VERSION: $DMG"
shasum -a 256 "$DMG"
[ $LOCAL = 1 ] && echo "(local test build: signed with this Mac's own identity, not notarized)"
exit 0
