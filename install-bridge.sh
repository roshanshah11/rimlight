#!/bin/sh
# install-bridge.sh: add the Rimlight bridge to Spicetify without restarting Spotify (-n; `spicetify apply` would
# relaunch it with `open -a` and steal focus). The bridge loads the next time Spotify starts.
# Undo: spicetify config extensions rimlight-bridge.js- && spicetify apply -n
set -e
cd "$(dirname "$0")"
cp spicetify/rimlight-bridge.js "$(spicetify path userdata)/Extensions/rimlight-bridge.js"
spicetify config extensions rimlight-bridge.js
spicetify apply -n
