#!/bin/sh
# build-app.sh: release build -> ~/Applications/Rimlight.app, signed with the stable self-signed identity from
# ~/Projects/imac/signing (so the system-audio permission survives rebuilds), plus ~/bin/rimlight for the CLI.
# Restarts the app if it was running. Launch goes through LaunchServices so macOS files the permission under
# Rimlight, not the terminal.
set -e
cd "$(dirname "$0")"
swift build -c release --product Rimlight
APP="$HOME/Applications/Rimlight.app"
was_running=0
if pgrep -x Rimlight >/dev/null; then was_running=1; osascript -e 'quit app "Rimlight"' || pkill -x Rimlight || true; fi
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Rimlight "$APP/Contents/MacOS/Rimlight"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.roshan.rimlight</string>
  <key>CFBundleName</key><string>Rimlight</string>
  <key>CFBundleExecutable</key><string>Rimlight</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Rimlight times your speakers or headphones by listening for short chirps on the MacBook's own mic, only while you calibrate. Nothing is recorded or saved.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Rimlight listens to what your Mac plays to time the glow to the beat. Nothing is recorded or saved.</string>
</dict>
</plist>
EOF
"$HOME/Projects/imac/signing/sign.sh" "$APP"
mkdir -p "$HOME/bin"
ln -sf "$APP/Contents/MacOS/Rimlight" "$HOME/bin/rimlight"
if [ "$was_running" = 1 ] || [ "$1" = "--launch" ]; then sleep 1; open -g "$APP"; fi
echo "installed $APP"
