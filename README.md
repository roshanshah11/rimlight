# Rimlight

A light show around the edges of the screen, played from the music. It follows a song the way DJ lighting does
(rekordbox's phrase analysis, SoundSwitch's bar-locked color changes): a calm wash in quiet parts, two-color pools
that swap on the beat in the groove, a chase that speeds up through a build, a blackout on the last moment before
the drop, and a white hit on the drop's downbeat. While the iMac stream is up, only the iMac glows.

Each song gets a style, judged from its first bars of music (`StyleJudge`: felt tempo, how much of the mix the bass
carries, whether a kick lands on every beat), and logged with its evidence to
`~/Library/Application Support/Rimlight/songs.jsonl`:
- **Club** (a kick on every beat at house tempo): builds, the blackout, the drop's white hit, chases.
- **Rap** (most of what he plays, and pop): the hook is the big look, found from the synced lyrics (`HookFinder`: the
  block of lines that comes back); verses are calm pools with no chase; the hits follow the 808s and claps as they're
  heard; the beat cutting out under the voice dims the rim, and coming back is a hit; only real silences go dark.
- **Ambiance** (slow songs whose bass doesn't dominate): a wash in the cover's colors that breathes over two bars and
  swells with the song, no hits. The menu's Ambiance style forces it.

A verdict only moves up (ambiance, rap, club) and starts from the last song's.

Research behind the rules: `~/roshan/Learning/Research/2026-10-24-dj-lighting-rimlight/answer.md`.

## Install and run

```
./build-app.sh            # release build -> ~/Applications/Rimlight.app (signed with ~/Projects/imac/signing), ~/bin/rimlight
./build-app.sh --launch   # and start it
./install-bridge.sh       # the Spicetify bridge; Spotify loads it on its next start
```

`rimlight status` shows the song, the look, where the beats come from, the timing correction and the screens.
`rimlight on|off|motion beat|flow|steady|brightness|strength|glow|thickness|offset <ms>` change settings live.
`rimlight calibrate` (or the menu's "Calibrate timing for these speakers or headphones…") times the current output
by ear: eight chirps play through it (headphones: one earcup held to the MacBook, by the keyboard) and the MacBook's
own mic times each one, so a Bluetooth headset's mic is never opened. With a song playing it also lines up the song as
the tap hears it with the mic's recording (`MusicSync`, cross-correlation weighted by phase), which times the whole way
from the tap to the ear with nothing assumed; that measurement wins when it's clear. It saves the difference from
macOS's figure for that output, and every run goes to `calibration-log.jsonl`. `rimlight calibrate manual` is the old way: clicks with a flash on the rim, → and ← move the flash onto
the click, Return saves it.

## Timing

Everything runs on "sound time": the host time the tapped app played each sample.

- **With Spotify's analysis** (the bridge): beats and bars come from Spotify's beat map; the song is planned ahead
  (`SongPlan`): builds, blackouts and drops land on their beats. Spotify's reported position is corrected by
  `GridCalibrator`, which measures it against the kicks the tap actually hears.
- **Live only**: `BeatClock` phase-locks to the kicks and announces each beat at its predicted time, so the light
  isn't late by the detector's ~30 ms. Builds are read from the highs taking over the mix (spectral tilt) or the
  bass being pulled; a gap of silence in a build goes dark, and the drop hits when the sound comes back.
- **Per song**: Spotify's map sits differently on each song's hits (-50 to +57 ms on eight songs, 2026-10-24/25), the
  same on the Beats and the speakers, so the correction is learned per song: the strong hits are folded onto half a
  beat (beats and off-beats alike, so a trap clap on the "and" can't pull it half a beat out) and the pile nearest the
  songs' running average wins. Replayed on four of his songs (Fixtures/onsets-2026-10-25.json) each settles within
  2 ms of its drums in 20-52 s; a song not settled after 15 s is lit from the live clock meanwhile. In rap, a heard hit
  is lit only if it lands on a 16th of the settled beat (10-44% of the hits on those songs didn't: voices and synths).
- **Screens**: each frame is drawn for when it reaches the screen (when Metal says it was presented, measured per
  screen: 16.7 ms after the display link's target on the MacBook, 2026-10-25, plus half a frame) minus the
  time from playing to hearing. On the iMac stream that's measured: the receiver reports its sound queue, speaker
  latency and picture delay once a second, the sender adds its own holds and writes
  `~/Library/Application Support/imac-display/av-sync.json` (50 ms when there's none). On this Mac's speakers or
  headphones it's the output's reported latency plus what `rimlight calibrate` found for that output. The chirps are
  timed from their output timestamps, so they're compared with macOS's figure minus one IO buffer (the tap hears a
  sample that long before its timestamp): on the MacBook speakers, measured 15.3 ms against macOS's 17.4.
  `rimlight offset <ms>` trims everything.
- **Memory**: the glow is drawn at one pixel per point with two drawables per strip, freed while idle; under memory
  pressure at half that, and not at all when it's critical. Lit on the MacBook: 122 MB (173 MB at Retina resolution),
  of which ~85 MB is a fixed GPU driver cost while drawing; 12-30 MB idle.

Measured on `SyntheticSong` (`swift test --filter TimingTests`): live kicks lit at +4 to +5 ms mean, 5 ms std;
the planned drop's white hit on the exact frame of the downbeat; the live one a frame later.

## Checks

- `swift test -c release`: 74 tests, including timing against the synthetic track, the three styles on synthetic club, trap and
  ballad tracks, and the song plan on three real Spotify analyses (Fixtures/).
- `rimlight debug-video out.mp4 [--live] [--cover image] [--song club|trap|ballad]`: a synthetic track through the
  show, with its audio.
- `rimlight calibrate selfcheck`: the chirps through the MacBook's own speakers (unmute them first), nothing saved;
  checks the method against an output macOS knows. 2026-10-25: 8 of 8 heard, 15.32 ms, spread 0.007 ms, -2 ms from
  macOS. `touch /tmp/rimlight-chirp-dump` first and the run writes `/tmp/rimlight-chirp.wav` and the chirps' times.
- `rimlight debug-lit <s>`: glow a fixed look for a few seconds without music (memory and CPU checks).
- `rimlight debug-plan analysis.json`: a Spotify analysis through the planner, bar by bar.
- `rimlight palette sheet.png covers...`: the light colors picked from album covers.
- `open -n -W -a ~/Applications/Rimlight.app --args debug-tap-compare out.txt`: the tap-only listener against the old
  one built on the output device (which flipped Bluetooth headphones to headset mode). 2026-10-24: 1.7 ms earlier, 12 of 12 clicks.
- `RIM_DEBUG=1 swift test --filter Debug`: per-bar traces of the live pipeline.
- `touch /tmp/rimlight-onset-dump` before launching: every heard hit against Spotify's map goes to
  `/tmp/rimlight-onsets.jsonl` (how the per-song fixture was made).
