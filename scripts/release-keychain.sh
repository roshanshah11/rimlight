#!/bin/sh
# release-keychain.sh: the keychain that holds the Developer ID signing key (~/Library/Keychains/
# rimlight-release.keychain-db, its password in the login keychain as "rimlight-release-keychain", both backed up
# in gopass under rimlight/). Sourced by release.sh: unlocks it and adds it to the search list until the shell
# exits (codesign only finds identities in the search list).
#   scripts/release-keychain.sh import <file.cer>   adds the certificate Apple issued for the key, and checks it
RKC="$HOME/Library/Keychains/rimlight-release.keychain-db"
rkc_open() {
  [ -f "$RKC" ] || return 1
  RKC_ORIG=$(security list-keychains -d user | tr -d '"' | xargs)
  security unlock-keychain -p "$(security find-generic-password -s rimlight-release-keychain -w)" "$RKC" || return 1
  security list-keychains -d user -s $RKC_ORIG "$RKC"
  trap 'security list-keychains -d user -s $RKC_ORIG' EXIT
}
if [ "$1" = "import" ]; then
  set -e
  [ -f "$2" ] || { echo "usage: scripts/release-keychain.sh import <developerID_application.cer>"; exit 2; }
  rkc_open
  security import "$2" -k "$RKC"
  security find-identity -v -p codesigning "$RKC"
fi
