#!/bin/sh
# build-app.sh: release build -> ~/Applications/Rimlight.app for this Mac, signed with the stable self-signed
# identity (scripts/sign-local.sh: the system-audio permission survives rebuilds), plus ~/bin/rimlight for the CLI.
# Restarts the app if it was running. Launch goes through LaunchServices so macOS files the permission under
# Rimlight, not the terminal. A release for other Macs is ./release.sh.
set -e
cd "$(dirname "$0")"
swift build -c release --product Rimlight
APP="$HOME/Applications/Rimlight.app"
was_running=0
if pgrep -x Rimlight >/dev/null; then was_running=1; osascript -e 'quit app "Rimlight"' || pkill -x Rimlight || true; fi
scripts/bundle.sh .build/release/Rimlight "$APP"
scripts/sign-local.sh "$APP"
mkdir -p "$HOME/bin"
ln -sf "$APP/Contents/MacOS/Rimlight" "$HOME/bin/rimlight"
if [ "$was_running" = 1 ] || [ "$1" = "--launch" ]; then sleep 1; open -g "$APP"; fi
echo "installed $APP ($(cat VERSION))"
