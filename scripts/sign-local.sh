#!/bin/sh
# sign-local.sh APP: sign with this Mac's stable self-signed identity ("iMac Display Signing", from
# ~/Projects/imac/signing/setup.sh), with the hardened runtime and entitlements a release has, so this Mac's
# build behaves like the one people download. The designated requirement stays "identifier + this certificate",
# so the audio and mic permissions survive rebuilds. codesign only finds identities in the search list, so the
# keychain joins it for the signing and the old list is put back.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$HOME/Projects/imac/signing"; KC="$D/imac-signing.keychain-db"
[ -f "$KC" ] || { echo "no local signing identity: run $D/setup.sh once"; exit 1; }
ORIG=$(security list-keychains -d user | tr -d '"' | xargs)
security unlock-keychain -p "$(cat "$D/keychain-pass")" "$KC"
security list-keychains -d user -s $ORIG "$KC"
if codesign --force --options runtime --entitlements "$ROOT/Resources/Rimlight.entitlements" -s "iMac Display Signing" "$1"; then rc=0; else rc=$?; fi
security list-keychains -d user -s $ORIG
exit $rc
