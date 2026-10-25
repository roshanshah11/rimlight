import Foundation

/// Runs a song through the same pipeline the app uses (detector, beat clock, director) in simulated real time, so
/// timing can be measured against the song's known beats. Frame `t` is drawn for the sound heard at `t`.
public enum ShowSimulator {
    public struct Frame: Sendable {
        public let t: Double; public let state: LightState; public var style: ShowStyle = .club
        public var ambiance = false   // the rim shows ambiance (the style, or no beat to follow)
    }

    public struct Result: Sendable {
        public let frames: [Frame]
        public var judged: [(evidence: StyleJudge.Evidence, style: ShowStyle)] = []
        /// Frames where the light visibly hits (pulse + flash jumps by more than 0.12).
        public var hits: [Double] {
            var out: [Double] = []
            var prev: Float = 0
            for f in frames {
                let v = f.state.pulse + f.state.flash
                if v - prev > 0.12 { out.append(f.t) }
                prev = v
            }
            return out
        }
        /// Frames where a white hit starts.
        public var flashes: [Double] {
            var out: [Double] = []
            var prev: Float = 0
            for f in frames {
                if f.state.flash > 0.5, prev <= 0.5 { out.append(f.t) }
                prev = f.state.flash
            }
            return out
        }
        public func section(at t: Double) -> Section? { frames.last { $0.t <= t }?.state.section }
    }

    public enum Mode: Sendable {
        case reactive      // light on each detected onset, as it's reported
        case predictive    // the beat clock announces beats at their predicted time
        case planned       // Spotify-style analysis: the beat grid and a SongPlan
    }

    /// `hooks`: the hook's times, as HookFinder would find them in the lyrics (planned mode). `style`: force one;
    /// nil lets the judge pick, starting from `startStyle` like the app does from the last song's. `latency`: how far
    /// the show runs behind the tap, as in the app, where the light waits for the sound to reach the ears (28 ms on
    /// the speakers, about 50 on the iMac stream, 160 on Bluetooth headphones); 0 shows each frame as soon as it's
    /// heard.
    public static func run(_ song: some TestTrack, mode: Mode, fps: Double = 60, palette: [RGB] = Palette.fallback,
                           hooks: [Range<Double>] = [], style: ShowStyle? = nil, startStyle: ShowStyle = .club,
                           latency: Double = 0,
                           until end: Double? = nil, onFrame: ((Double, LightState, ShowStyle) -> Void)? = nil) -> Result {
        let sr = song.sampleRate
        let det = BeatDetector(sampleRate: sr)
        let clock = BeatClock()
        let director = ShowDirector(palette: palette)
        director.setStyle(startStyle)
        director.forcedStyle = style
        let analysis = song.analysis
        if mode == .planned { director.setPlan(SongPlan.make(analysis, hooks: hooks)); director.onGrid = true }
        let downbeats = Set(analysis.bars.map { Int(($0 * 1000).rounded()) })

        let block = 512
        var consumed = 0
        var lastOnset = -10.0
        var nextGridBeat = 0
        var prevT = 0.0
        var frames: [Frame] = []
        let duration = end ?? Double(song.samples.count) / sr
        var t = 0.0
        // a frame is on screen for 1/fps; it shows the moment halfway through, so errors center on zero
        let half = 0.5 / fps
        song.samples.withUnsafeBufferPointer { all in
            while t < duration {
                let at = t + half
                while consumed + block <= all.count, Double(consumed + block) / sr <= t + latency {
                    let found = det.process(UnsafeBufferPointer(rebasing: all[consumed..<(consumed + block)]))
                    _ = det.drainBeats()
                    consumed += block
                    for b in found {
                        lastOnset = b.time
                        clock.onset(at: b.time, strength: b.strength)
                        director.heard(onset: b.time, strength: b.strength)
                        if mode == .reactive {   // (predictive never lights raw reports, like the app since 2026-10-25)
                            director.beat(at: b.time, strength: b.strength)
                        }
                    }
                    clock.setTempo(det.tempo)
                }
                switch mode {
                case .predictive:
                    for bt in clock.beats(after: prevT, through: at, lastOnset: lastOnset) {
                        director.beat(at: bt, strength: 0.8)
                    }
                case .planned:
                    while nextGridBeat < analysis.beats.count, analysis.beats[nextGridBeat] <= at {
                        let bt = analysis.beats[nextGridBeat]
                        director.beat(at: bt, strength: 0.8, downbeat: downbeats.contains(Int((bt * 1000).rounded())),
                                      trackTime: bt)
                        nextGridBeat += 1
                    }
                case .reactive:
                    break
                }
                let f = det.features
                let input = MusicInput(energy: f.loudness, level: f.level, bass: f.lowLoud, treble: f.highLoud,
                                       tempo: mode == .planned ? analysis.tempo : (clock.locked ? clock.period.map { 60 / $0 } : det.tempo),
                                       trackTime: mode == .planned ? at : nil, tilt: f.tilt, bassShare: f.bassShare, crest: f.crest, lowLevel: f.lowLevel)
                let s = director.frame(at: at, input)
                if ProcessInfo.processInfo.environment["RIM_TRACE"] != nil, let drop = (song as? SyntheticSong)?.dropTime,
                   t > drop - 1.2, t < drop + 0.3 {
                    print(String(format: "trace %.3f level %.2f loud %.2f armed %d section %@", t - drop, f.level, f.loudness, director.debugArmed ? 1 : 0, s.section.rawValue))
                }
                frames.append(Frame(t: t, state: s, style: director.style, ambiance: director.showingAmbiance))
                onFrame?(t, s, director.style)
                prevT = at
                t += 1 / fps
            }
        }
        return Result(frames: frames, judged: director.judge.history)
    }
}
