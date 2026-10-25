# Rimlight

Rimlight lights the edges of your Mac's screen to the music you're playing. It runs the way a DJ's lights do: a soft
wash in slow songs, colors that swap on the beat, a chase that speeds up through a build and a white hit when the
drop lands. In Spotify and Apple Music the colors come from the album art.

It lives in the menu bar, works with any app that plays sound, and is free and open source (MIT).

**[Download the latest release](https://github.com/roshanshah11/rimlight/releases/latest)**

## Requirements

- macOS 15 (Sequoia) or later, on Apple silicon or Intel.
- Music from any app. Spotify and Apple Music also give Rimlight the song's name and cover.

## Install

1. Open the DMG and drag Rimlight into Applications.
2. Open Rimlight. A welcome window explains what it does; choose whether it opens at login and press Start.
3. macOS asks to let Rimlight record system audio. Allow it: that's how the light hears the beat. If you said no,
   turn it on in System Settings › Privacy & Security › Screen & System Audio Recording, under System Audio
   Recording Only. The menu offers a shortcut there whenever Rimlight hears only silence.

Rimlight checks GitHub once a day for a newer release and offers it in the menu (More › Check for updates turns
that off).

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
  reaches, how hard the beats hit, the edge's thickness, album colors, white hits on drops, the Spotify extension,
  opening at login, update checks, and options that appear only on screens that have them (the notch, HDR).

Each song gets a style from its first bars: **club** for a kick on every beat, **rap** for most hip-hop and pop (the
hits follow the 808s and claps), and **ambiance** for slow songs.

When Spotify or Apple Music has a song on, its play state decides: pausing the song fades the light even if a video
plays elsewhere. With neither open, any app's sound lights it.

## The Spotify extension

On its own, Rimlight follows the beat it hears. With its Spotify extension it also gets Spotify's beat map, the song's
sections and its synced lyrics, and plans the show to the song: builds and drops land on their beats, and a rap song's
hook (the lines that come back) gets the big look. This makes the biggest difference on rap, whose offbeat 808s are
hard to follow by ear.

The extension runs inside Spotify through [Spicetify](https://spicetify.app), an unofficial Spotify mod. Install
Spicetify first, then choose More › Add Rimlight's extension to Spotify and reopen Spotify. From a clone of this repo,
`./install-bridge.sh` does the same. The extension talks only to Rimlight on your Mac (`ws://127.0.0.1:47811`).
Spotify updates can undo Spicetify; `spicetify update` (or `spicetify backup apply`) puts it back.

## Privacy

- Rimlight listens to the sound your Mac plays to find the beat. It analyzes it in memory as it plays and keeps none
  of it: nothing is saved or sent anywhere.
- The mic is used only while you calibrate, to hear the chirps. Nothing from it is saved.
- To color the light from album art it downloads the cover: for a Spotify song from Spotify's public pages
  (open.spotify.com and its image server), for an Apple Music song by searching Apple's public iTunes Search for the
  artist and album.
- Once a day it asks GitHub for the latest release (api.github.com), unless you turn that off.
- Nothing else leaves your Mac. There are no accounts, analytics or tracking. Settings and logs stay in
  `~/Library/Application Support/Rimlight`.

## Uninstall

Turn off More › Open at login, quit Rimlight from its menu, drag it from Applications to the Trash, and delete
`~/Library/Application Support/Rimlight`. To remove the Spotify extension:
`spicetify config extensions rimlight-bridge.js- && spicetify apply`.

## Building from source

Needs Xcode 16 or later (Swift 6 tools) on macOS 15 or later.

```
./build-app.sh             # builds and installs ~/Applications/Rimlight.app, plus ~/bin/rimlight for the CLI
./build-app.sh --launch    # and starts it
swift test -c release      # the tests
```

`build-app.sh` signs ad hoc unless it finds a stable self-signed identity (see `scripts/sign-local.sh`), so macOS asks
for the audio permission again after each rebuild. `rimlight help` lists the command line; `rimlight status` shows
the song, the look, where the beats come from and the timing. How the show and its timing work is in
[DEVELOPMENT.md](DEVELOPMENT.md).

## Contributing

Issues and pull requests are welcome. Keep `swift test -c release` passing (GitHub runs it on every push and pull
request), and add a test with any change to the show or its timing: `Sources/RimlightCore` holds the logic, with no
AppKit, and the tests drive it with synthetic songs and recordings of real ones.

## Releasing

For maintainers. A release that opens on other Macs is signed with a Developer ID and notarized by Apple:

1. Once per Mac: the Developer ID Application certificate and its key in the release keychain
   (`scripts/release-keychain.sh import <certificate.cer>`), and notary credentials saved as the keychain profile
   `rimlight-notary` (`xcrun notarytool store-credentials rimlight-notary --key AuthKey_<id>.p8 --key-id <id>
   --issuer <issuer id>`).
2. Set the version in `VERSION` and commit it.
3. `./release.sh --publish`: runs the tests, builds for Apple silicon and Intel, signs with the hardened runtime,
   has Apple notarize the app and the DMG, staples both, checks them with Gatekeeper, then tags the commit and
   publishes the DMG as a GitHub release. Without `--publish` it stops at the DMG in `dist/`; `--local` checks the
   packaging with this Mac's own identity, not notarized.

The icon is drawn by `scripts/make-icon.swift`.

## License

MIT. See [LICENSE](LICENSE).
