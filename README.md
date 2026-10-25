# Rimlight

Rimlight lights the edges of your Mac's screen to the music you're playing. It runs the way a DJ's lights do: a soft
wash in slow songs, colors that swap on the beat, a chase that speeds up through a build and a white hit when the
drop lands. In Spotify and Apple Music the colors come from the album art.

It lives in the menu bar and needs no setup beyond one permission.

## Requirements

- macOS 15 (Sequoia) or later, on Apple silicon or Intel.
- Music from any app. Spotify and Apple Music also give Rimlight the song's name and cover.

## Install

1. Open `Rimlight-1.0.0.dmg` and drag Rimlight into Applications.
2. Open Rimlight. A welcome window explains what it does; choose whether it opens at login and press Start.
3. macOS asks to let Rimlight record system audio. Allow it: that's how the light hears the beat. If you said no,
   turn it on in System Settings › Privacy & Security › Screen & System Audio Recording, under System Audio
   Recording Only. The menu offers a shortcut there whenever Rimlight hears only silence.

## Using it

Click the rays icon in the menu bar:

- **Light show** turns it on and off. It fades out by itself when the music stops.
- **Brightness** and **Sync** (move the light earlier or later if it doesn't sit on the beat).
- **Calibrate timing for these speakers or headphones** times your current output. Bluetooth headphones can be
  slower than macOS reports, so this matters most for them: hold one earcup against your Mac (on a MacBook, by the
  keyboard) and press Start. Eight short chirps play and your Mac's built-in mic times them. With a song playing,
  Rimlight also times the song itself on its way to your ears. A Mac without a built-in mic can adjust by hand
  instead: clicks play with a flash on the screen's edge, and you move the flash onto the click.
- **More** holds the look: the show (picked per song), Ambiance (a slow wash, no hits) or Steady; how far the glow
  reaches, how hard the beats hit, the edge's thickness, album colors, white hits on drops, opening at login, and
  options that appear only on screens that have them (the notch, HDR).

Each song gets a style from its first bars: **club** for a kick on every beat, **rap** for most hip-hop and pop (the
hits follow the 808s and claps), and **ambiance** for slow songs.

When Spotify or Apple Music has a song on, its play state decides: pausing the song fades the light even if a video plays
elsewhere. With neither open, any app's sound lights it.

## Privacy

- Rimlight listens to the sound your Mac plays to find the beat. It analyzes it in memory as it plays and keeps none
  of it: nothing is saved or sent anywhere.
- The mic is used only while you calibrate, to hear the chirps. Nothing from it is saved.
- To color the light from album art it downloads the cover: for a Spotify song from Spotify's public pages
  (open.spotify.com and its image server), for an Apple Music song by searching Apple's public iTunes Search for the
  artist and album. Nothing else leaves your Mac, and there are no accounts, analytics or tracking.
- Its settings and logs stay in `~/Library/Application Support/Rimlight`.

## Uninstall

Turn off More › Open at login, quit Rimlight from its menu, drag it from Applications to the Trash, and delete
`~/Library/Application Support/Rimlight`.

## Building

```
./build-app.sh             # builds and installs ~/Applications/Rimlight.app for this Mac, plus ~/bin/rimlight
swift test -c release      # the tests
./release.sh --local       # a test of the release packaging: universal app and DMG in dist/, not notarized
./release.sh               # the real release: Developer ID signed, notarized, stapled
```

The version is in `VERSION`; the build number is the commit count. `scripts/make-icon.swift` redraws the icon.
How the show and its timing work is in `DEVELOPMENT.md`.

### Releasing

A release that opens on other Macs needs two things in this Mac's keychain, once:

1. A **Developer ID Application** certificate from the Apple Developer account (Xcode › Settings › Accounts ›
   Manage Certificates › +, or developer.apple.com › Certificates). Only the account holder can create one.
2. Notary credentials saved as the profile `rimlight-notary`:
   `xcrun notarytool store-credentials rimlight-notary --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer id>`
   (an App Store Connect API key), or `--apple-id <email> --team-id <team>` with an app-specific password.

Then `./release.sh` runs the tests, builds for Apple silicon and Intel, signs with the hardened runtime, has Apple
notarize the app and the DMG, staples both, checks them with Gatekeeper and prints the DMG's SHA-256.

### The Spotify extension (optional)

`./install-bridge.sh` adds a small Spicetify extension to Spotify. With it, Rimlight plans the show from Spotify's own
beat map and section analysis (builds and drops land on their beats, and a rap song's hook comes from its synced
lyrics). Spicetify is an unofficial Spotify mod, and the extension reads Spotify's internal endpoints, so it isn't
part of what ships: without it, Rimlight follows the beat it hears.

## License

Copyright © 2026 Roshan Shah. All rights reserved. See `LICENSE`.
