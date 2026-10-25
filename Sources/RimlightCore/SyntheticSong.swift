import Foundation

/// A dance track built from known parts, so timing can be measured against the truth: 8 bars of intro (pad and hats,
/// no kick), 8 bars of groove, an 8-bar build (snare roll speeding up from quarters to 32nds, a rising noise sweep,
/// the kick cut for the last four bars, and a two-beat gap of silence before the drop), 8 bars of drop, then 4 bars of
/// breakdown. 128 BPM, bar 1 beat 1 at t = 0.
public struct SyntheticSong: Sendable {
    public let sampleRate: Double
    public let bpm: Double
    public let samples: [Float]

    public static let introBars = 0..<8, grooveBars = 8..<16, buildBars = 16..<24, dropBars = 24..<32, outroBars = 32..<36
    public static let barCount = 36

    public var beat: Double { 60 / bpm }
    public var bar: Double { beat * 4 }
    public var beats: [Double] { (0..<(Self.barCount * 4)).map { Double($0) * beat } }
    public var bars: [Double] { (0..<Self.barCount).map { Double($0) * bar } }
    /// The drop's first downbeat.
    public var dropTime: Double { Double(Self.dropBars.lowerBound) * bar }
    /// The silence before the drop: the last two beats of the build.
    public var gap: Range<Double> { (dropTime - 2 * beat)..<dropTime }
    /// Beats that carry a kick (the ones a light show should hit).
    public var kickBeats: [Double] {
        beats.enumerated().filter { i, t in
            let b = i / 4
            return Self.grooveBars.contains(b) || Self.dropBars.contains(b) || (Self.buildBars.contains(b) && b < 20)
        }.map(\.1)
    }

    public func section(atBar b: Int) -> Section {
        if Self.grooveBars.contains(b) { return .groove }
        if Self.buildBars.contains(b) { return .build }
        if Self.dropBars.contains(b) { return .drop }
        return .quiet
    }

    public init(sampleRate: Double = 48000, bpm: Double = 128) {
        self.sampleRate = sampleRate
        self.bpm = bpm
        let beat = 60 / bpm, bar = beat * 4
        let n = Int(Double(Self.barCount) * bar * sampleRate)
        var out = [Float](repeating: 0, count: n)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func noise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed) >> 11) / Float(1 << 52)
        }
        func add(_ start: Double, _ dur: Double, _ f: (Double) -> Float) {
            let s = Int(start * sampleRate), e = min(n, Int((start + dur) * sampleRate))
            guard s < n else { return }
            for i in max(0, s)..<e { out[i] += f(Double(i - s) / sampleRate) }
        }
        func kick(_ t: Double, _ gain: Float) {
            add(t, 0.35) { x in gain * Float(sin(2 * .pi * (50 * x + 100 * (1 - exp(-x * 30)) / 30)) * exp(-x * 8)) }
        }
        func clap(_ t: Double, _ gain: Float) { add(t, 0.15) { x in gain * noise() * Float(exp(-x * 28)) } }
        func hat(_ t: Double, _ gain: Float) {
            var prev: Float = 0
            add(t, 0.06) { x in let w = noise(); defer { prev = w }; return gain * (w - prev) * 0.5 * Float(exp(-x * 70)) }
        }
        func bass(_ t: Double, _ dur: Double, _ gain: Float) {
            add(t, dur) { x in
                let ph = 2 * .pi * 55 * x
                return gain * Float(sin(ph) + 0.5 * sin(2 * ph) + 0.25 * sin(3 * ph)) * Float(min(1, x * 200, (dur - x) * 200))
            }
        }
        func pad(_ t: Double, _ dur: Double, _ gain: Float) {
            add(t, dur) { x in
                let env = Float(min(1, x * 50, (dur - x) * 50))     // sustained: 20 ms edges
                return gain * env * Float(sin(2 * .pi * 220 * x) + sin(2 * .pi * 261.63 * x) + sin(2 * .pi * 329.63 * x)) / 3
            }
        }

        for b in 0..<Self.barCount {
            let t0 = Double(b) * bar
            switch b {
            case Self.introBars, Self.outroBars:
                pad(t0, bar, 0.12)
                for k in 0..<8 { hat(t0 + Double(k) * beat / 2, 0.05) }
            case Self.grooveBars:
                pad(t0, bar, 0.08)
                for k in 0..<4 {
                    kick(t0 + Double(k) * beat, 0.6)
                    bass(t0 + Double(k) * beat + beat / 2, beat / 2 * 0.9, 0.12)
                    hat(t0 + Double(k) * beat + beat / 2, 0.08)
                }
                clap(t0 + beat, 0.2); clap(t0 + 3 * beat, 0.2)
            case Self.buildBars:
                let i = b - Self.buildBars.lowerBound          // 0...7
                pad(t0, i == 7 ? 2 * beat : bar, 0.08 + 0.01 * Float(i))   // everything stops for the gap
                if b < 20 { for k in 0..<4 { kick(t0 + Double(k) * beat, 0.55) } }
                let per = i < 2 ? 1 : (i < 4 ? 2 : (i < 6 ? 4 : 8))   // hits per beat: quarters to 32nds
                let lastBar = i == 7
                for k in 0..<(4 * per) {
                    let t = t0 + Double(k) * beat / Double(per)
                    if lastBar, t >= t0 + 2 * beat { break }       // the gap
                    clap(t, 0.12 + 0.12 * Float(i) / 7)
                }
                // rising noise sweep, cut at the gap
                let sweepEnd = lastBar ? 2 * beat : bar
                var lp: Float = 0
                let start = Double(i) / 8
                add(t0, sweepEnd) { x in
                    let p = start + x / bar / 8
                    let a = Float(0.02 + 0.6 * p * p)
                    let w = noise()
                    lp += (w - lp) * Float(0.05 + 0.9 * p)
                    return a * (w - lp) * 0.5
                }
            case Self.dropBars:
                pad(t0, bar, 0.16)
                for k in 0..<4 {
                    kick(t0 + Double(k) * beat, 0.8)
                    bass(t0 + Double(k) * beat + beat / 2, beat / 2 * 0.9, 0.2)
                    hat(t0 + Double(k) * beat + beat / 2, 0.12)
                    hat(t0 + Double(k) * beat + beat / 4 * 3, 0.06)
                }
                clap(t0 + beat, 0.3); clap(t0 + 3 * beat, 0.3)
            default:
                break
            }
        }
        var peak: Float = 0
        for x in out { peak = max(peak, abs(x)) }
        if peak > 0.95 { let g = 0.95 / peak; for i in out.indices { out[i] *= g } }
        samples = out
    }

    /// What Spotify's analysis would say about this track: beats, bars, sections, and each beat's loudness (dB).
    public var analysis: SongAnalysis {
        let per = Int(beat * sampleRate)
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
        func sec(_ r: Range<Int>) -> SongAnalysis.SongSection {
            let l = loud[(r.lowerBound * 4)..<(r.upperBound * 4)]
            return .init(start: Double(r.lowerBound) * bar, duration: Double(r.count) * bar, loudness: l.reduce(0, +) / Double(l.count))
        }
        return SongAnalysis(tempo: bpm, beats: beats, bars: bars,
                            sections: [sec(Self.introBars), sec(Self.grooveBars), sec(Self.buildBars), sec(Self.dropBars), sec(Self.outroBars)],
                            beatLoudness: loud)
    }
}
