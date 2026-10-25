import Foundation

/// A song the simulator can play: its audio, its true beats and bars, and what Spotify's analysis would say.
public protocol TestTrack: Sendable {
    var name: String { get }
    var sampleRate: Double { get }
    var bpm: Double { get }
    var samples: [Float] { get }
    var analysis: SongAnalysis { get }
}

public extension TestTrack {
    var beat: Double { 60 / bpm }
    var bar: Double { beat * 4 }
    var duration: Double { Double(samples.count) / sampleRate }
}

extension SyntheticSong: TestTrack {
    public var name: String { "synthetic club track" }
}

extension SongAnalysis {
    /// Spotify-style loudness for known beats: each beat's loudest 50 ms (dB), and each section's mean.
    static func measure(_ samples: [Float], sampleRate: Double, tempo: Double, beats: [Double], bars: [Double],
                        sections: [Range<Int>]) -> SongAnalysis {
        let per = Int(60 / tempo * sampleRate)
        let win = Int(0.05 * sampleRate)
        let loud = beats.map { t -> Double in
            let s = Int(t * sampleRate), e = min(samples.count, s + per)
            var best: Double = 1e-10
            var w = s
            while w + win <= e {
                var acc: Double = 0
                for i in w..<(w + win) { acc += Double(samples[i] * samples[i]) }
                best = max(best, acc / Double(win))
                w += win / 2
            }
            return 10 * log10(best)
        }
        let bar = 4 * 60 / tempo
        let secs = sections.map { r -> SongSection in
            let l = loud[(r.lowerBound * 4)..<min(loud.count, r.upperBound * 4)]
            return .init(start: Double(r.lowerBound) * bar, duration: Double(r.count) * bar, loudness: l.reduce(0, +) / Double(max(1, l.count)))
        }
        return SongAnalysis(tempo: tempo, beats: beats, bars: bars, sections: secs, beatLoudness: loud)
    }
}

/// The instruments the synthetic genres are built from, written into one buffer.
final class Synth {
    let sampleRate: Double
    private(set) var out: [Float]
    private var seed: UInt64 = 0x2545F4914F6CDD1D

    init(seconds: Double, sampleRate: Double) {
        self.sampleRate = sampleRate
        out = [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    func noise() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: seed) >> 11) / Float(1 << 52)
    }

    func add(_ start: Double, _ dur: Double, _ f: (Double) -> Float) {
        let n = out.count
        let s = Int(start * sampleRate), e = min(n, Int((start + dur) * sampleRate))
        guard s < n else { return }
        for i in max(0, s)..<e { out[i] += f(Double(i - s) / sampleRate) }
    }

    /// A punchy kick (pitch drop 150 -> 50 Hz).
    func kick(_ t: Double, _ gain: Float, decay: Double = 8) {
        add(t, 0.35) { x in gain * Float(sin(2 * .pi * (50 * x + 100 * (1 - exp(-x * 30)) / 30)) * exp(-x * decay)) }
    }

    /// A trap 808: a click, then a long sub tone that glides down into its note.
    func eightOhEight(_ t: Double, _ dur: Double, _ gain: Float, hz: Double = 46) {
        add(t, dur) { x in
            let ph = 2 * .pi * (hz * x + hz * 0.6 * (1 - exp(-x * 25)) / 25)
            let env = Float(min(1, x * 400) * exp(-x * 1.1) * min(1, (dur - x) * 60))
            let click = Float(exp(-x * 120)) * 0.5
            return gain * env * (Float(sin(ph)) + click * Float(sin(ph * 3)))
        }
    }

    func clap(_ t: Double, _ gain: Float) { add(t, 0.15) { x in gain * self.noise() * Float(exp(-x * 28)) } }

    /// A soft rim click (ballads).
    func rim(_ t: Double, _ gain: Float) {
        add(t, 0.05) { x in gain * Float(sin(2 * .pi * 1700 * x) * exp(-x * 90)) + gain * 0.3 * self.noise() * Float(exp(-x * 140)) }
    }

    func hat(_ t: Double, _ gain: Float) {
        var prev: Float = 0
        add(t, 0.05) { x in let w = self.noise(); defer { prev = w }; return gain * (w - prev) * 0.5 * Float(exp(-x * 80)) }
    }

    /// A sustained chord.
    func pad(_ t: Double, _ dur: Double, _ gain: Float, _ hz: [Double]) {
        add(t, dur) { x in
            let env = Float(min(1, x * 6, (dur - x) * 6))
            return gain * env * Float(hz.map { sin(2 * .pi * $0 * x) }.reduce(0, +) / Double(hz.count))
        }
    }

    /// A plucked note (keys, piano-ish).
    func pluck(_ t: Double, _ gain: Float, _ hz: Double) {
        add(t, 1.2) { x in gain * Float((sin(2 * .pi * hz * x) + 0.3 * sin(4 * .pi * hz * x)) * exp(-x * 3.5) * min(1, x * 300)) }
    }

    /// A rapped syllable stand-in: a buzzy mid tone with a short envelope (fills the mids like a voice).
    func syllable(_ t: Double, _ dur: Double, _ gain: Float, hz: Double = 170) {
        add(t, dur) { x in
            let saw = 2 * (hz * x - floor(hz * x + 0.5))
            let formant = sin(2 * .pi * 700 * x) * 0.5
            let env = min(1, x * 80, (dur - x) * 40)
            return gain * Float((saw * 0.6 + formant) * env)
        }
    }

    func normalized() -> [Float] {
        var peak: Float = 0
        for x in out { peak = max(peak, abs(x)) }
        guard peak > 0.95 else { return out }
        let g = 0.95 / peak
        return out.map { $0 * g }
    }
}

/// A rap track, the shape of most current rap (Drake, DDG, EsDeeKid): 150 BPM as Spotify counts it, a
/// half-time feel (clap on 3), syncopated 808s, 8th hats with rolls. 4 bars of intro (keys only), a 16-bar verse
/// whose last two beats drop the beat out, an 8-bar hook (a lead and a doubled voice on top, harder 808s), an 8-bar
/// second verse that ends in two beats of silence, an 8-bar beat switch (new pattern, new chords), 4 bars of outro.
public struct SyntheticTrap: TestTrack {
    public enum Part: String, Sendable { case intro, verse, hook, beatSwitch, outro }
    public let name = "synthetic trap track"
    public let sampleRate: Double
    public let bpm: Double = 150
    public let samples: [Float]
    /// When each 808 and clap hits (the hits a rap show should land on).
    public let hits: [Double]

    public static let parts: [(Part, Range<Int>)] = [(.intro, 0..<4), (.verse, 4..<20), (.hook, 20..<28),
                                                     (.verse, 28..<36), (.beatSwitch, 36..<44), (.outro, 44..<48)]
    public static let barCount = 48
    public var hookTime: Double { 20 * bar }
    public var switchTime: Double { 36 * bar }
    /// The beat cut out under the voice (the last two beats of the first verse).
    public var dropout: Range<Double> { (hookTime - 2 * beat)..<hookTime }
    public var beats: [Double] { (0..<(Self.barCount * 4)).map { Double($0) * beat } }
    public var bars: [Double] { (0..<Self.barCount).map { Double($0) * bar } }

    public func part(atBar b: Int) -> Part { Self.parts.first { $0.1.contains(b) }?.0 ?? .outro }

    public init(sampleRate: Double = 48000) {
        self.sampleRate = sampleRate
        let beat = 60 / 150.0, bar = 4 * beat, step = beat / 4
        let s = Synth(seconds: Double(Self.barCount) * bar, sampleRate: sampleRate)
        var hits: [Double] = []
        let chords: [[Double]] = [[220, 261.6, 329.6], [196, 246.9, 293.7], [174.6, 220, 261.6], [196, 246.9, 311.1]]
        let switchChords: [[Double]] = [[233.1, 277.2, 349.2], [207.7, 261.6, 311.1]]
        // two-bar 808 patterns in 16th steps (0...31) and their notes
        let verse808: [(Int, Double)] = [(0, 46), (10, 46), (16, 41), (22, 41), (27, 46)]
        let switch808: [(Int, Double)] = [(0, 52), (6, 52), (12, 49), (16, 52), (19, 52), (24, 46)]
        for b in 0..<Self.barCount {
            let t0 = Double(b) * bar
            let p = Self.parts.first { $0.1.contains(b) }?.0 ?? .outro
            let ch = p == .beatSwitch ? switchChords[b % 2] : chords[b % 4]
            switch p {
            case .intro, .outro:
                s.pad(t0, bar, 0.05, ch)
                for k in 0..<4 { s.pluck(t0 + Double(k) * beat, 0.08, ch[k % 3] * 2) }
            case .verse, .hook, .beatSwitch:
                let hook = p == .hook
                let lastVerseBar = b == 19 || b == 35
                let cutFrom = t0 + 2 * beat                      // the dropout / the silence before the switch
                s.pad(t0, bar, hook ? 0.06 : 0.04, ch)
                let pattern = p == .beatSwitch ? switch808 : verse808
                for (st, hz) in pattern where (b % 2 == 0 ? st < 16 : st >= 16) {
                    let t = t0 + Double(st % 16) * step
                    if lastVerseBar, t >= cutFrom { continue }
                    s.eightOhEight(t, lastVerseBar ? min(0.9, cutFrom - t) : 0.9, hook ? 0.55 : 0.45, hz: hz)   // muted at the cut
                    hits.append(t)
                    s.kick(t, hook ? 0.5 : 0.4, decay: 14)
                }
                if !lastVerseBar { s.clap(t0 + 2 * beat, hook ? 0.32 : 0.26); hits.append(t0 + 2 * beat) }
                for k in 0..<8 {
                    let t = t0 + Double(k) * beat / 2
                    if lastVerseBar, t >= cutFrom { break }
                    s.hat(t, 0.06)
                    if k == 7, b % 4 == 3 { for r in 1..<4 { s.hat(t + Double(r) * step / 2, 0.05) } }   // a roll
                }
                // the voice: rapped 8ths on the verses, held notes doubled on the hook; it keeps going through the
                // dropout, but not the silence before the switch
                for k in 0..<8 {
                    let t = t0 + Double(k) * beat / 2
                    if b == 35, t >= cutFrom { break }
                    s.syllable(t, beat / 2 * 0.8, hook ? 0.11 : 0.09, hz: hook ? 196 : 165)
                    if hook { s.syllable(t + 0.012, beat / 2 * 0.8, 0.06, hz: 294) }
                }
                if hook { s.pad(t0, bar, 0.05, ch.map { $0 * 2 }) }   // the lead
            }
        }
        samples = s.normalized()
        self.hits = hits.sorted()
    }

    public var analysis: SongAnalysis {
        SongAnalysis.measure(samples, sampleRate: sampleRate, tempo: bpm, beats: beats, bars: bars, sections: Self.parts.map(\.1))
    }
}

/// A slow song (an R&B ballad): 70 BPM, a soft kick and rim, pads and keys. 2 bars of intro, an 8-bar verse, a
/// 6-bar chorus (fuller, a little louder), 4 bars of outro. The rim should breathe with it, not hit.
public struct SyntheticBallad: TestTrack {
    public let name = "synthetic ballad"
    public let sampleRate: Double
    public let bpm: Double = 70
    public let samples: [Float]

    public static let barCount = 20
    public static let chorusBars = 10..<16
    public var beats: [Double] { (0..<(Self.barCount * 4)).map { Double($0) * beat } }
    public var bars: [Double] { (0..<Self.barCount).map { Double($0) * bar } }

    public init(sampleRate: Double = 48000) {
        self.sampleRate = sampleRate
        let beat = 60 / 70.0, bar = 4 * beat
        let s = Synth(seconds: Double(Self.barCount) * bar, sampleRate: sampleRate)
        let chords: [[Double]] = [[261.6, 329.6, 392], [220, 261.6, 329.6], [174.6, 220, 261.6], [196, 246.9, 293.7]]
        for b in 0..<Self.barCount {
            let t0 = Double(b) * bar
            let ch = chords[b % 4]
            let chorus = Self.chorusBars.contains(b)
            let drums = b >= 2 && b < 16
            s.pad(t0, bar, chorus ? 0.12 : 0.09, ch)
            if chorus { s.pad(t0, bar, 0.05, ch.map { $0 / 2 }) }
            for k in 0..<8 { s.pluck(t0 + Double(k) * beat / 2, 0.05, ch[k % 3] * (k % 2 == 0 ? 2 : 1.5)) }
            guard drums else { continue }
            s.kick(t0, 0.18, decay: 6)
            if chorus { s.kick(t0 + 2 * beat, 0.15, decay: 6) }
            s.rim(t0 + beat, 0.06); s.rim(t0 + 3 * beat, 0.06)
        }
        samples = s.normalized()
    }

    public var analysis: SongAnalysis {
        SongAnalysis.measure(samples, sampleRate: sampleRate, tempo: bpm, beats: beats, bars: bars,
                             sections: [0..<2, 2..<10, Self.chorusBars, 16..<20])
    }
}
