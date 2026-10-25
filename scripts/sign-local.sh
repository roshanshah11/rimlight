#!/bin/sh
# sign-local.sh APP: sign a build for this Mac with the hardened runtime and entitlements a release has, so it
# behaves like the one people download. With the stable self-signed identity "iMac Display Signing" (from
# ~/Projects/imac/signing/setup.sh) the designated requirement stays "identifier + this certificate" and the audio
# and mic permissions survive rebuilds; without it the build is signed ad hoc, and macOS asks again after each
# rebuild. codesign only finds identities in the search list, so that keychain joins it for the signing and the old
# list is put back.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENT="$ROOT/Resources/Rimlight.entitlements"
D="$HOME/Projects/imac/signing"; KC="$D/imac-signing.keychain-db"
if [ ! -f "$KC" ]; then
  echo "sign-local.sh: no stable identity here, signing ad hoc (permissions reset with each rebuild)"
  exec codesign --force --options runtime --entitlements "$ENT" -s - "$1"
fi
ORIG=$(security list-keychains -d user | tr -d '"' | xargs)
security unlock-keychain -p "$(cat "$D/keychain-pass")" "$KC"
security list-keychains -d user -s $ORIG "$KC"
if codesign --force --options runtime --entitlements "$ENT" -s "iMac Display Signing" "$1"; then rc=0; else rc=$?; fi
security list-keychains -d user -s $ORIG
exit $rc
