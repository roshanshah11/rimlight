#!/bin/sh
# bundle.sh BINARY APP: assemble Rimlight.app from a built binary: the executable, the icon, and Info.plist with
# the version from VERSION and the build number from the commit count. Signing is the caller's (build-app.sh for
# this Mac, release.sh for a release).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$1"; APP="$2"
VERSION="$(cat "$ROOT/VERSION")"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rimlight"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
