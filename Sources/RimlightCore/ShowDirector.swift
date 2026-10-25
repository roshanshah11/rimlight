import Foundation

/// How hard the song drives, like rekordbox's mood (HIGH / MID / LOW, from tempo, rhythm, kick and density).
public enum Mood: String, Sendable { case low, mid, high }

/// Where the song is, in the terms DJ lighting uses (rekordbox's phrases: Down, Verse, Up, Chorus).
public enum Section: String, Sendable, CaseIterable {
    case quiet    // intro, breakdown: one slow color wash
    case groove   // verse: pools in two colors that swap on the beat
    case build    // riser: a chase that speeds up while everything brightens
    case drop     // chorus / drop: one white hit, then everything at full on every beat
}

/// One frame of the light show, read by the shader. Colors are linear sRGB.
public struct LightState: Equatable, Sendable {
    public var section: Section = .quiet
    public var master: Float = 0          // overall level
    public var bloom: Float = 0.8         // how far the light reaches in (0...1)
    public var pulse: Float = 0           // beat envelope
    public var flash: Float = 0           // white hit
    public var dark: Float = 0            // 1 = the pre-drop blackout
    public var wash = SIMD3<Float>(0.5, 0.4, 1)
    public var washLevel: Float = 1
    public var colorA = SIMD3<Float>(0.5, 0.4, 1)
    public var colorB = SIMD3<Float>(1, 0.4, 0.7)
    public var fixtures: Float = 6        // pools along each half of the rim (the two halves mirror)
    public var fixtureLevel: Float = 0
    public var alternate: Float = 0       // which color the even pools take; whole steps swap, fractions drift
    public var chasePos: Float = 0        // 0 = bottom center, 1 = top center, on both sides at once
    public var chaseWidth: Float = 0.08
    public var chaseLevel: Float = 0
    public var chaseColor = SIMD3<Float>(1, 1, 1)
    public init() {}
}

/// What the director hears each frame.
public struct MusicInput: Sendable {
    public var energy: Float          // smoothed loudness, 0...1
    public var level: Float           // instantaneous loudness, 0...1 (finds the gap before a drop)
    public var bass: Float
    public var treble: Float
    public var tempo: Double?         // BPM, when known
    public var trackTime: Double?     // Spotify's position (calibrated), when a plan is in use
    public var tilt: Float            // highs over the whole mix, dB (climbs through a build)
    public var bassShare: Float       // the kick and bass band against the mix, dB (StyleJudge)
    public var crest: Float           // how spiky the sound is, dB (StyleJudge)
    public var lowLevel: Float        // the kick and bass band right now, unsmoothed (dropouts)
    public init(energy: Float, level: Float? = nil, bass: Float = 0.5, treble: Float = 0.5, tempo: Double? = nil,
                trackTime: Double? = nil, tilt: Float = 0, bassShare: Float = 0, crest: Float = 0, lowLevel: Float? = nil) {
        self.energy = energy; self.level = level ?? energy; self.bass = bass; self.treble = treble
        self.tempo = tempo; self.trackTime = trackTime; self.tilt = tilt; self.bassShare = bassShare; self.crest = crest
        self.lowLevel = lowLevel ?? bass
    }
}

/// Turns beats and loudness into a designed show. With Spotify's analysis it plans ahead (SongPlan): builds start
/// on time, the last half beat before a drop goes dark, and the white hit lands on the drop's downbeat. Without it,
/// it follows the loudness: looks change on bar lines, a gap of silence in a build arms the drop for the next
/// downbeat. Colors rotate every 8 bars; nothing jumps in brightness or swaps color more than 3 times a second.
///
/// Each song gets a style (StyleJudge, from its first bars of music): club as above; hip-hop lights the hook (from
/// the lyrics) instead of drops, hits on the 808 and the clap as they're heard, dims when the beat cuts out under the
/// voice and hits when it slams back, and keeps the verses calm; ambient is a breathing wash with no hits.
public final class ShowDirector {
    public private(set) var section: Section = .quiet
    /// This song's style; `forcedStyle` (Flow) overrides the judge.
    public private(set) var style: ShowStyle = .club
    public var forcedStyle: ShowStyle? { didSet { if let f = forcedStyle { style = f } } }
    public private(set) var judge = StyleJudge()
    public private(set) var beatIndex = 0
    public private(set) var plan: SongPlan?
    public private(set) var mood: Mood = .mid
    public var debugArmed: Bool { armed }
    public var debugAmbientMix: Float { ambientMix }
    /// Music is playing but no beat has been found for a while (the live clock can't lock, no beat map): the show
    /// holds as ambiance instead of flashing at random onsets.
    public private(set) var beatless = false
    /// What's on the rim right now is ambiance (the style, or no beat to follow).
    public var showingAmbiance: Bool { ambientMix > 0.5 }
    public var allowFlashes = true

    public static let beatsPerBar = 4, barsPerPhrase = 8
    /// Minimum time between full-rim brightness jumps or color swaps: at most 3 per second (WCAG 2.3.1).
    public static let minFlashGap = 1.0 / 3.0 + 0.001
    /// The beats are on the music (Spotify's map once its correction settled, or the live clock locked): a rap hit
    /// is only lit if it's on a 16th of them, within this much. On his songs 10 to 44% of the heard hits were off the
    /// 16ths (voices and synths with no drum under them), and lit, they read as random (2026-10-25).
    public var onGrid = false
    public static let gridTolerance = 0.025

    private var palette: [SIMD3<Float>]
    private var lastBeat = -10.0
    private var previousBeat = -10.0
    private var period = 0.5
    private var intervals: [Double] = []
    private var synthesized = 0
    private var downbeatOffset = 0
    private var slotStrength = [Float](repeating: 0, count: 4)
    private var knownDownbeats = false

    private var eLong: Float = 0.6
    private var eShort: Float = 0, eFast: Float = 0, level: Float = 0, bass: Float = 0, treble: Float = 0
    private var energyPerBeat: [Float] = []
    private var treblePerBeat: [Float] = []
    private var bassPerBeat: [Float] = []
    private var tilt: Float = 0
    private var tiltPerBeat: [Float] = []
    private var armedAt = 0.0
    private var target: Section = .quiet
    private var targetSince = 0
    private var sectionStartBeat = 0
    private var buildProgress: Float = 0
    private var lastFrame = 0.0
    private var bassShare: Float = 0, crest: Float = 0, lowNow: Float = 0
    private var eSlow: Float = 0.5
    private var ambientMix: Float = 0
    private var breathPhase = 0.0
    private var lastRealBeat = -100.0, musicSince: Double?
    private var accents: [(t: Double, s: Float)] = []
    private var dim: Float = 0
    private var hookLevel: Float = 0
    private var loudQuietBeats = 0
    private var dropoutSince: Double?
    private var inDropout = false

    private var lastPulseAt = -10.0, lastFlashAt = -10.0, lastSwapAt = -10.0
    private var pulseEnv: Float = 0, flashEnv: Float = 0, dark: Float = 0
    private var swaps = 0
    private var phrase = 0
    private var washFrom = SIMD3<Float>(0.5, 0.4, 1), washTo = SIMD3<Float>(0.5, 0.4, 1)
    private var washChangeAt = -10.0, washFadeTime = 2.0
    private var monochromeUntilBeat = -1

    // live drops: a gap in a build arms the drop for the next downbeat
    private var gapSince: Double?
    private var armed = false
    private var confirmBy: Double?
    private var sectionBeforeDrop: Section = .build

    public init(palette: [RGB]) {
        self.palette = Self.prepare(palette)
        washFrom = self.palette[0]; washTo = self.palette[0]
    }

    private static func prepare(_ p: [RGB]) -> [SIMD3<Float>] {
        let c = (p.isEmpty ? Palette.fallback : p).map { rgb -> SIMD3<Float> in
            let l = rgb.linear
            return SIMD3(Float(l.0), Float(l.1), Float(l.2))
        }
        return c.count == 1 ? [c[0], c[0]] : c
    }

    /// New song colors (blended in over a second).
    public func setPalette(_ p: [RGB], at time: Double) {
        palette = Self.prepare(p)
        phrase = 0
        setWash(palette[0], at: time, fade: 1.0)
    }

    /// The analysis plan for the current song, or nil to follow loudness alone.
    public func setPlan(_ p: SongPlan?) { plan = p }

    /// The style to start a song in until the judge has heard enough (the last song's, or the app's default).
    public func setStyle(_ s: ShowStyle) { style = forcedStyle ?? s }

    /// An onset the tap heard (sound time): evidence for the style, and in hip-hop the 808 and clap hits.
    public func heard(onset t: Double, strength: Float) {
        judge.onset(at: t, strength: strength)
        if style == .hiphop, strength >= 0.3 {   // the detector hears mostly the low band: these are 808s, kicks, claps
            accents.append((t, strength))
            if accents.count > 16 { accents.removeFirst(accents.count - 16) }
        }
    }

    /// A new song: start from a calm look; keep the colors.
    public func reset() {
        section = .quiet; target = .quiet; targetSince = beatIndex; sectionStartBeat = beatIndex
        intervals = []; synthesized = 0; knownDownbeats = false; slotStrength = [0, 0, 0, 0]
        energyPerBeat = []; treblePerBeat = []; bassPerBeat = []; tiltPerBeat = []; armed = false; gapSince = nil; confirmBy = nil; dark = 0
        lastBeat = -10; plan = nil; lastRealBeat = -100; musicSince = nil; beatless = false
        judge = StyleJudge(); accents = []; dim = 0; dropoutSince = nil; inDropout = false; loudQuietBeats = 0
    }

    private func color(_ i: Int) -> SIMD3<Float> { palette[((i % palette.count) + palette.count) % palette.count] }

    private func setWash(_ c: SIMD3<Float>, at time: Double, fade: Double) {
        washFrom = currentWash(time)
        washTo = c
        washChangeAt = time
        washFadeTime = fade
    }

    private func currentWash(_ time: Double) -> SIMD3<Float> {
        guard washFadeTime > 0 else { return washTo }
        let x = Float(min(1, max(0, (time - washChangeAt) / washFadeTime)))
        let k = x * x * (3 - 2 * x)
        return washFrom + (washTo - washFrom) * k
    }

    // MARK: beats

    /// The beat of the bar this beat index falls on (0 = downbeat).
    public func beatInBar(_ i: Int) -> Int { ((i - downbeatOffset) % 4 + 4) % 4 }

    /// Above ~145 BPM the light moves on every other beat (half time), so a double-time count never makes a
    /// slow song frantic and swaps stay under 3 a second.
    public var lightEvery: Int { period < 60.0 / 145 ? 2 : 1 }

    private var phraseBeats: Int { Self.beatsPerBar * Self.barsPerPhrase * lightEvery }

    /// A beat at `time` (when it's heard). Onsets closer than ~70% of a beat to the last one are ignored.
    /// `downbeat` and `trackTime` come from Spotify's analysis when the bridge has it.
    public func beat(at time: Double, strength: Float, downbeat: Bool? = nil, trackTime: Double? = nil) {
        let gap = time - lastBeat
        // a real beat replaces a filled-in one that landed off the new grid (no double count)
        if synthesized > 0, gap >= 0.12, gap < period * 0.7 {
            lastBeat = time
            synthesized = 0
            return
        }
        guard gap >= max(0.2, period * 0.7) else { return }
        if gap < 2 {
            intervals.append(gap)
            if intervals.count > 12 { intervals.removeFirst(intervals.count - 12) }
        }
        previousBeat = lastBeat
        lastBeat = time
        lastRealBeat = time
        synthesized = 0
        advanceBeat(at: time, strength: strength, downbeat: downbeat, trackTime: trackTime)
    }

    /// `counted`: a beat filled in for a missed kick. It keeps the bar count; it never lights (it's found late).
    private func advanceBeat(at time: Double, strength: Float, downbeat: Bool?, trackTime: Double?, counted: Bool = false) {
        beatIndex += 1
        if let d = downbeat {
            knownDownbeats = true
            if d { downbeatOffset = beatIndex % 4 }
        } else if !knownDownbeats {
            // the slot with clearly stronger kicks is the "one" (four-on-the-floor has none; keep the guess)
            let slot = beatIndex % 4
            slotStrength[slot] = slotStrength[slot] * 0.8 + strength * 0.2
            let mean = slotStrength.reduce(0, +) / 4
            if beatIndex % 16 == 0, let best = slotStrength.indices.max(by: { slotStrength[$0] < slotStrength[$1] }),
               slotStrength[best] - mean > 0.12 {
                downbeatOffset = best
            }
        }
        energyPerBeat.append(eFast)
        treblePerBeat.append(treble)
        bassPerBeat.append(bass)
        tiltPerBeat.append(tilt)
        if tiltPerBeat.count > 32 { tiltPerBeat.removeFirst(tiltPerBeat.count - 32) }
        if bassPerBeat.count > 32 { bassPerBeat.removeFirst(bassPerBeat.count - 32) }
        if energyPerBeat.count > 64 { energyPerBeat.removeFirst(energyPerBeat.count - 64) }
        if treblePerBeat.count > 64 { treblePerBeat.removeFirst(treblePerBeat.count - 64) }
        // a beat after two seconds without one starts a new pattern: in music that's a downbeat
        if !knownDownbeats, time - previousBeat > 2 { downbeatOffset = beatIndex % 4 }

        let bar = beatInBar(beatIndex) == 0
        if let plan, let tt = trackTime, let cue = plan.cue(at: tt) {
            followPlan(style == .club ? cue : hipHopCue(cue, plan: plan, at: tt), at: time)
        } else if !armed {
            decideSection(onDownbeat: bar, at: time)
        }
        // the style is judged on the song's music, not its intro: beats outside quiet parts, or a song that stays
        // "quiet" with bass under it for four bars (a ballad never has the beat come in, and a quiet master reads
        // low against the loudness guess; an intro of pads and hats has no bass and is still an intro)
        loudQuietBeats = section == .quiet && eShort > 0.15 && bassShare > 2 ? loudQuietBeats + 1 : 0
        // and only while the tap hears it: with no audio (the tap restarting, a Spotify device elsewhere) every
        // measure reads zero, which judged Don Toliver's "Rendezvous" ambiance (2026-10-25)
        if eShort > 0.15, section != .quiet || loudQuietBeats > 16 {
            judge.beat(at: time, feltBPM: 60 / (period * Double(lightEvery)), bassShare: bassShare, crest: crest)
            if forcedStyle == nil, let v = judge.verdict { style = v }
        }
        if bar, (beatIndex - sectionStartBeat) % phraseBeats == 0, beatIndex != sectionStartBeat {
            nextPhrase(at: time)
        }

        let lit = lightEvery == 1 || beatInBar(beatIndex) % 2 == 0
        guard lit, !counted, !armed, time - lastPulseAt >= Self.minFlashGap else { return }
        lastPulseAt = time
        // in hip-hop the grid keeps time softly; the punch comes from the hits as they're heard
        let accent: Float = style == .hiphop ? (bar ? 0.5 : 0.25) : (bar ? 1 : 0.7)
        pulseEnv = max(pulseEnv, min(1, 0.4 + 0.6 * strength) * accent)
        // the groove's color swap: every beat when the song drives, every other beat in the middle, once a bar
        // when it's slow and mellow (a slow jam lit like house music looks frantic); a drop always swaps on the beat
        let slot = beatInBar(beatIndex) / lightEvery
        let swapHere = style == .hiphop
            ? (section == .drop ? slot % 2 == 0 : bar)            // hook: every other beat; verse: once a bar
            : section == .drop || mood == .high || (mood == .mid && slot % 2 == 0) || (mood == .low && bar)
        if section == .groove || section == .drop, swapHere, time - lastSwapAt >= Self.minFlashGap {
            swaps += 1
            lastSwapAt = time
        }
        if allowFlashes, style == .club, section == .drop, bar, time - lastFlashAt >= Self.minFlashGap {
            flashEnv = max(flashEnv, beatIndex - sectionStartBeat < 4 ? 1 : 0.45)
            lastFlashAt = time
        }
    }

    private func followPlan(_ cue: SongPlan.Cue, at time: Double) {
        if case .build(let p) = cue { buildProgress = p }
        let s = cue.section
        guard s != section else { return }
        enter(s, at: time)
    }

    /// Rap and pop with the analysis: the hook (from the lyrics) is the big look; there are no builds; the plan's
    /// loud jumps stand in for the hook only when the lyrics found none.
    private func hipHopCue(_ cue: SongPlan.Cue, plan: SongPlan, at tt: Double) -> SongPlan.Cue {
        if plan.inHook(tt) { return .drop }
        guard let b = plan.barIndex(at: tt) else { return .quiet }
        if plan.energy[b] < 0.35 { return .quiet }
        // a loud jump is the hook only out of music: out of an intro it's just the beat coming in
        if case .drop = cue, plan.hooks.isEmpty, b >= 2, plan.energy[(b - 2)..<b].allSatisfy({ $0 >= 0.35 }) {
            if let start = plan.drops.last(where: { $0 <= tt + 0.03 }), let sb = plan.barIndex(at: start), sb >= 2,
               plan.energy[(sb - 2)..<sb].allSatisfy({ $0 >= 0.35 }) { return .drop }
        }
        return .groove
    }

    private func nextPhrase(at time: Double) {
        phrase += 1
        setWash(color(phrase), at: time, fade: style == .ambient ? 6 : (section == .quiet ? period * 4 : 0.08))
    }

    private func energy(beatsAgo n: Int) -> Float {
        energyPerBeat.count > n ? energyPerBeat[energyPerBeat.count - 1 - n] : eShort
    }

    private func treble(beatsAgo n: Int) -> Float {
        treblePerBeat.count > n ? treblePerBeat[treblePerBeat.count - 1 - n] : treble
    }

    private func decideSection(onDownbeat: Bool, at time: Double) {
        // a build: the kick and bass pulled out while the highs (snare rolls, risers) carry a still-loud track,
        // or the highs climbing over four bars, or loudness climbing over four bars
        // rising means still rising: up over four bars and over the last bar too (a jump that then sits flat,
        // like the kick coming in after an intro, is not a build)
        // (per-beat history holds the fast follower; compare it with itself so smoothing lag doesn't hide a ramp)
        let rise16 = max(eFast - energy(beatsAgo: 16), (treble - treble(beatsAgo: 16)) * 1.2)
        let rise4 = max(eFast - energy(beatsAgo: 4), (treble - treble(beatsAgo: 4)) * 1.2)
        let rise = rise4 > 0.02 ? rise16 : 0
        // the highs taking over the mix: 4 dB above where they sat a few bars ago and still climbing
        let tiltBase = tiltPerBeat.dropLast(8).suffix(16).min() ?? tilt
        let tiltBack = tiltPerBeat.count > 4 ? tiltPerBeat[tiltPerBeat.count - 5] : tilt
        let highsRising = tiltPerBeat.count >= 12 && tilt - tiltBase >= 4 && tilt - tiltBack >= 0.8
        // "cut" means the bass was there in the last four bars and is gone now (not that it never came in)
        let hadBass = (bassPerBeat.suffix(16).max() ?? 0) > 0.6
        let bassCut = hadBass && bass < 0.3 && treble > 0.6 && eShort > 0.4
        let before = (2...5).map { energy(beatsAgo: $0) }.reduce(0, +) / 4
        let jump = eFast - before
        let inSection = beatIndex - sectionStartBeat
        let phrase = Self.beatsPerBar * Self.barsPerPhrase * lightEvery
        // Live, a drop is a moment, not a level: the first loud part of a song is always the loudest so far. It is
        // the jump into loudness out of a quiet part or a build; it holds for a phrase, then relaxes to groove so
        // the next one can land.
        var t: Section
        if style != .club {
            // rap, pop and slow songs: no risers to build on. The hook is the song getting fuller for a while; it
            // holds four bars, then as long as the energy it came in with stays
            if eFast < 0.3, eShort < 0.4 { t = .quiet }
            else if section == .quiet, jump > 0.2 { t = .groove }
            else if section == .groove, inSection >= 8, eFast > 0.7, jump > 0.12 { t = .drop }
            else if section == .drop, inSection < 16 * lightEvery || eFast > hookLevel - 0.12, inSection < 2 * phrase { t = .drop }
            else { t = .groove }
            if t != target { target = t; targetSince = beatIndex }
            let held = beatIndex - targetSince
            let landing = target == .drop || (target == .groove && section == .quiet)
            guard target != section, landing || (onDownbeat && held >= 2) || (target == .quiet && held >= 2) else { return }
            if target == .drop { hookLevel = eFast }
            enter(target, at: time)
            return
        }
        if eFast < 0.3, eShort < 0.4, section != .build { t = .quiet }
        else if section == .build, eFast > 0.7, jump > 0.18 { t = .drop }
        else if section == .groove, inSection >= 8, eFast > 0.75, jump > 0.25 { t = .drop }   // a chorus slams in
        else if section == .drop, inSection < phrase, eShort > 0.5 { t = .drop }
        else if section == .quiet, jump > 0.25 { t = .groove }                // the beat came in
        else if section == .groove, inSection < 8, !bassCut { t = .groove }     // and settles for two bars
        else if section != .drop, bassCut || highsRising || rise > 0.1 { t = .build }
        else { t = .groove }
        // a build holds until its drop (or 16 bars), even through the bars where the kick is cut
        if section == .build, t == .groove || t == .quiet, eShort > 0.25, inSection < 2 * phrase { t = .build }

        if t != target { target = t; targetSince = beatIndex }
        let held = beatIndex - targetSince
        let landing = (target == .drop && (section == .build || section == .groove))
            || (target == .groove && section == .quiet && jump > 0.25)
        let breakdown = target == .quiet && eFast < 0.25 && held >= 1     // the music clearly dropped out
        let building = target == .build && held >= 2                     // a build ramps; it needn't wait for the bar
        guard target != section, landing || breakdown || building || (onDownbeat && held >= 2) else { return }
        if target == .build { buildProgress = 0 }
        enter(target, at: time)
    }

    private func enter(_ s: Section, at time: Double) {
        let from = section
        section = s
        target = s
        targetSince = beatIndex
        sectionStartBeat = beatIndex
        switch s {
        case .drop:
            sectionBeforeDrop = from
            armed = false
            gapSince = nil
            dark = 0
            phrase += 1
            setWash(color(phrase), at: time, fade: 0.05)
            monochromeUntilBeat = beatIndex + Self.beatsPerBar   // the first bar of a drop is one color
            if from != .drop, allowFlashes, style != .ambient, time - lastFlashAt >= Self.minFlashGap {
                flashEnv = style == .hiphop ? 0.7 : 1
                lastFlashAt = time
                lastPulseAt = time
            }
        case .quiet:
            setWash(currentWash(time), at: time, fade: 0)
        case .groove:
            if from == .quiet { pulseEnv = 1; lastPulseAt = time }
        case .build:
            break
        }
    }

    // MARK: frames

    /// Convenience for loudness-only callers.
    public func frame(at time: Double, energy: Float, bass: Float, treble: Float, tempo: Double?) -> LightState {
        frame(at: time, MusicInput(energy: energy, bass: bass, treble: treble, tempo: tempo))
    }

    /// The look at `time`.
    public func frame(at time: Double, _ m: MusicInput) -> LightState {
        let dt = Float(min(0.1, max(0, time - lastFrame)))
        lastFrame = time
        eShort += (m.energy - eShort) * min(1, dt / 1.2)
        eFast += (m.energy - eFast) * min(1, dt / 0.2)
        eLong += (m.energy - eLong) * min(1, dt / 20)
        level = m.level
        bass += (m.bass - bass) * min(1, dt / 0.3)
        treble += (m.treble - treble) * min(1, dt / 0.6)
        tilt += (m.tilt - tilt) * min(1, dt / 0.5)
        bassShare = m.bassShare
        lowNow += (m.lowLevel - lowNow) * min(1, dt / 0.06)
        crest = m.crest
        eSlow += (m.energy - eSlow) * min(1, dt / 3)
        // ten seconds of music with no beat to follow: ambiance until one turns up
        if eShort > 0.15 { if musicSince == nil { musicSince = time } } else { musicSince = nil }
        beatless = (musicSince.map { time - $0 > 10 } ?? false) && time - lastRealBeat > 10
        ambientMix += ((style == .ambient || beatless ? 1 : 0) - ambientMix) * min(1, dt / 1.5)
        // one breath every two bars (6 to 12 s); the phase accumulates so a tempo change doesn't make it jump
        breathPhase += Double(dt) / min(12, max(6, 8 * period))

        if let bpm = m.tempo, bpm >= 60, bpm <= 200 { period = 60 / bpm }
        else if intervals.count >= 4 { period = min(1, max(0.3, intervals.sorted()[intervals.count / 2])) }
        let feltBPM = 60 / (period * Double(lightEvery))
        mood = feltBPM < 98 || eLong < 0.45 ? .low : (feltBPM >= 118 && eLong > 0.65 ? .high : .mid)

        // keep counting through a missed kick (up to two bars), so the chase stays on the beat
        if plan == nil, time - lastBeat > period * 1.2, synthesized < 8, eShort > 0.25, lastBeat > 0 {
            lastBeat += period
            synthesized += 1
            advanceBeat(at: lastBeat, strength: 0.4, downbeat: nil, trackTime: nil, counted: true)
        }

        // the pre-drop blackout: planned, or the gap of silence in a build
        var darkTarget: Float = 0
        if style == .ambient {
            gapSince = nil; armed = false
        } else if style == .hiphop, let plan, let tt = m.trackTime {
            if plan.inGap(tt) { darkTarget = 1 }
        } else if let plan, let tt = m.trackTime, plan.inBlackout(tt) {
            darkTarget = 1
        } else if plan != nil, section == .build, level < 0.15 {
            darkTarget = 1                                    // planned, but the music went silent anyway
        } else if plan == nil, section == .build || section == .groove || armed {
            // a gap: everything falls more than ~20 dB under the song's loudest for 90 ms. Go dark and wait;
            // the drop is the moment the sound comes back loud (the level reacts within ~10 ms, well before
            // a beat could be confirmed). After two bars of nothing, give up.
            if level < 0.15 {
                if gapSince == nil { gapSince = time }
                // in a build 90 ms of silence is the setup; in a groove it has to last most of a beat
                let need = section == .build ? 0.03 : 0.75 * period
                if !armed, time - (gapSince ?? time) >= need { armed = true; armedAt = time }
            } else {
                gapSince = nil
                if armed, level > 0.6 {
                    if style == .hiphop {   // the beat slams back after a silence: a hit, not a new section
                        armed = false
                        hit(at: time, flash: true)
                    } else {
                        enter(.drop, at: time); confirmBy = time + 0.25
                    }
                }
            }
            if armed, time - armedAt > 8 * period { armed = false; enter(.quiet, at: time) }
            if armed { darkTarget = 1 }
        }
        // a drop that came out of a gap but no sound followed: undo it
        if let by = confirmBy, time >= by {
            confirmBy = nil
            if section == .drop, level < 0.2, eFast < 0.35 { enter(sectionBeforeDrop == .drop ? .build : sectionBeforeDrop, at: time) }
        }
        dark += (darkTarget - dark) * min(1, dt / (darkTarget > dark ? 0.015 : 0.05))

        pulseEnv *= exp(-dt / 0.13)
        flashEnv *= exp(-dt / 0.09)
        // hip-hop: the hits as heard, at their own time (an onset found a frame late still starts mid-decay, in phase)
        while let a = accents.first, a.t <= time {
            accents.removeFirst()
            guard style == .hiphop, section != .quiet, dark < 0.5, a.t - lastPulseAt >= Self.minFlashGap else { continue }
            if onGrid, time - lastBeat < 2 * period {
                let q = period / 4, x = a.t - lastBeat
                guard abs(x - q * (x / q).rounded()) <= Self.gridTolerance else { continue }
            }
            lastPulseAt = a.t
            pulseEnv = max(pulseEnv, min(1, 0.3 + 0.7 * a.s) * Float(exp(-(time - a.t) / 0.13)))
        }
        // hip-hop: the beat cutting out under the voice (bass gone for most of a beat, the mix still going) dims the
        // rim to the wash; the beat coming back is a hit
        if style == .hiphop, section != .quiet {
            if lowNow < 0.35, eShort > 0.3 {
                if dropoutSince == nil { dropoutSince = time }
                if !inDropout, time - (dropoutSince ?? time) >= 0.5 * period { inDropout = true }
            } else {
                dropoutSince = nil
                if inDropout, lowNow > 0.6 { inDropout = false; hit(at: time, flash: false) }
            }
        } else { inDropout = false; dropoutSince = nil }
        dim += ((inDropout ? 1 : 0) - dim) * min(1, dt / (inDropout ? 0.08 : 0.04))
        let beatFrac = Float(min(1, max(0, (time - lastBeat) / period)))
        let phase = Float(beatIndex - sectionStartBeat) + beatFrac
        let inSection = Float(beatIndex - sectionStartBeat)
        // a chase never sweeps faster than once per 0.35 s, so it moves instead of jumping between frames
        let minSweepBeats = Float(max(1, (0.35 / period).rounded(.up)))

        var t = LightState()
        t.section = section
        t.pulse = pulseEnv
        t.flash = flashEnv
        t.dark = dark
        t.wash = currentWash(time)
        t.colorA = color(phrase)
        t.colorB = beatIndex < monochromeUntilBeat ? color(phrase) : color(phrase + 1)
        t.alternate = Float(swaps % 2)
        t.chaseColor = color(phrase + 1) * 0.5 + SIMD3<Float>(repeating: 0.5)

        switch section {
        case .quiet:
            t.master = 0.55 + 0.35 * eShort
            t.bloom = 1
            t.washLevel = 0.6
            t.fixtures = 2
            t.fixtureLevel = 0.5
            t.alternate = Float((time * 0.05).truncatingRemainder(dividingBy: 2))
            t.pulse = pulseEnv * 0.15
        case .groove:
            t.master = 0.75 + 0.2 * eShort
            t.bloom = 0.7
            t.washLevel = 0.12        // a low base, so each pool keeps its own color instead of mixing
            t.fixtures = 3
            t.fixtureLevel = 0.85
            t.chaseLevel = 0.35
            t.chasePos = (phase / max(mood == .low ? 16 : 8, minSweepBeats)).truncatingRemainder(dividingBy: 1)
            t.chaseWidth = 0.1
            t.pulse = pulseEnv * (mood == .low ? 0.4 : 0.6)
        case .build:
            let progress = plan != nil ? buildProgress : min(1, inSection / 16)
            t.master = 0.55 + 0.45 * progress
            t.bloom = 0.5 + 0.5 * progress
            t.washLevel = 0.15
            t.fixtures = 3 + 3 * progress
            t.fixtureLevel = 0.5 + 0.4 * progress
            t.colorB = t.colorA                                            // one color, getting brighter
            let sweep = max(minSweepBeats, progress < 0.5 ? 4 : (progress < 0.85 ? 2 : 1))
            t.chasePos = (phase / sweep).truncatingRemainder(dividingBy: 1)
            t.chaseLevel = 0.5 + 0.5 * progress
            t.chaseWidth = 0.07
            t.pulse = pulseEnv * 0.5
        case .drop:
            t.master = 1
            t.bloom = 1
            t.washLevel = 0.15
            t.fixtures = 2
            t.fixtureLevel = 1
            t.chasePos = (phase / minSweepBeats).truncatingRemainder(dividingBy: 1)
            t.chaseLevel = 0.8
            t.chaseWidth = 0.12
            t.pulse = pulseEnv
        }
        if style == .hiphop {
            switch section {
            case .groove, .build:                       // verse: calm pools, no chase
                t.chaseLevel = 0
                t.master = 0.62 + 0.15 * eShort + (section == .build ? 0.06 : 0)
                t.bloom = 0.65
                t.fixtures = 3
                t.fixtureLevel = 0.85
                t.colorB = beatIndex < monochromeUntilBeat ? color(phrase) : color(phrase + 1)
                t.pulse = pulseEnv * 0.8
            case .drop:                                 // the hook: everything up, a slow sweep
                t.master = 0.95
                t.chasePos = (phase / max(16, minSweepBeats)).truncatingRemainder(dividingBy: 1)
                t.chaseLevel = 0.35
            case .quiet:
                break
            }
            t.master *= 1 - 0.55 * dim
            t.fixtureLevel *= 1 - 0.7 * dim
            t.chaseLevel *= 1 - dim
        }
        t.chaseLevel *= 0.6 + 0.4 * treble
        t.master *= 1 - 0.96 * dark
        t.pulse *= 1 - dark
        if ambientMix > 0.001 { blend(&t, toward: ambientLook(time), by: ambientMix) }
        return t
    }

    /// A hit outside the grid: the beat coming back after a cut. Pulse, a color swap, and a soft white hit after a
    /// silence (never more than 3 a second).
    private func hit(at time: Double, flash: Bool) {
        guard time - lastPulseAt >= Self.minFlashGap else { return }
        lastPulseAt = time
        pulseEnv = 1
        if time - lastSwapAt >= Self.minFlashGap { swaps += 1; lastSwapAt = time }
        if flash, allowFlashes, time - lastFlashAt >= Self.minFlashGap { flashEnv = 0.6; lastFlashAt = time }
    }

    /// Ambiance: the cover's colors as a wash that breathes over two bars and swells with the song, no hits.
    private func ambientLook(_ time: Double) -> LightState {
        var a = LightState()
        a.section = section
        a.master = 0.5 + 0.35 * eSlow + 0.06 * Float(sin(2 * .pi * breathPhase))
        a.bloom = 1
        a.wash = currentWash(time)
        a.washLevel = 0.75
        a.colorA = color(phrase)
        a.colorB = color(phrase + 1)
        a.fixtures = 2
        a.fixtureLevel = 0.45
        a.alternate = Float((time * 0.04).truncatingRemainder(dividingBy: 2))
        a.pulse = 0
        a.flash = 0
        a.dark = 0
        return a
    }

    private func blend(_ t: inout LightState, toward a: LightState, by k: Float) {
        func mix(_ x: Float, _ y: Float) -> Float { x + (y - x) * k }
        func mix(_ x: SIMD3<Float>, _ y: SIMD3<Float>) -> SIMD3<Float> { x + (y - x) * k }
        t.master = mix(t.master, a.master); t.bloom = mix(t.bloom, a.bloom); t.pulse = mix(t.pulse, a.pulse)
        t.flash = mix(t.flash, a.flash); t.dark = mix(t.dark, a.dark); t.wash = mix(t.wash, a.wash)
        t.washLevel = mix(t.washLevel, a.washLevel); t.colorA = mix(t.colorA, a.colorA); t.colorB = mix(t.colorB, a.colorB)
        t.fixtures = mix(t.fixtures, a.fixtures); t.fixtureLevel = mix(t.fixtureLevel, a.fixtureLevel)
        t.alternate = k > 0.5 ? a.alternate : t.alternate
        t.chaseLevel = mix(t.chaseLevel, 0)
    }
}
