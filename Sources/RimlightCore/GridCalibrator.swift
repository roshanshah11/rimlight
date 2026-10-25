import Foundation

/// Spotify reports where it is in the track, but not exactly when that sound comes out: its beat map sits a little
/// off the audio it actually plays, by a different amount on each song (+32, +6 and -50 ms on three songs 2026-10-24;
/// 0, +8, +19 and +21 ms on four more 2026-10-25, on the Beats and the speakers alike). The tap hears the real audio,
/// so each detected hit is matched to the map and the song's correction (sound time minus map time) is learned on its
/// own: `newTrack()` forgets the last song's hits and starts from its offset.
///
/// Every drum hit in his music lands on an 8th note, the off-beat as often as the beat (a trap clap or 808 on the
/// "and"), so a new song folds its hits onto half a beat and takes the place they pile up nearest the starting guess,
/// never more than a quarter beat from it. The guess is the songs' running average, kept within 30 ms of zero: every
/// song so far sits within 60 ms of that, inside a quarter beat up to 250 BPM. Folding onto the whole beat instead let
/// the off-beat pile win: "Plot Twist" settled at -223 ms, half a beat wrong, and the next songs started from it
/// (2026-10-25); starting from the last song's own offset put a 152 BPM song's pile on the wrong side of the fold.
public final class GridCalibrator {
    public private(set) var offset: Double = 0
    public private(set) var confident = false
    public private(set) var spread: Double = 0     // median absolute deviation of the matches, seconds
    /// This song's offset has been measured (not just carried over from the last one).
    public private(set) var settled = false
    private var samples: [Double] = []
    private var wide: [(x: Double, s: Float)] = []   // each strong hit's place in its 8th, from the guess, while unsettled
    private var heard = 0
    private var guess: Double = 0
    /// The settled songs' running average: the next song's starting guess (saved across launches).
    public private(set) var baseline: Double

    /// How far from zero the starting guess may be.
    public static let guessRange = 0.03
    private static func clamp(_ v: Double) -> Double { max(-guessRange, min(guessRange, v)) }

    public init(offset: Double = 0) {
        baseline = Self.clamp(offset)
        self.offset = baseline
        guess = baseline
    }

    /// A new song (or a new output): learn its offset from scratch, starting from `seed` or the songs' average.
    public func newTrack(seed: Double? = nil) {
        offset = Self.clamp(seed ?? baseline)
        guess = offset
        samples = []
        wide = []
        heard = 0
        confident = false
        settled = false
        spread = 0
    }

    /// A detected onset at `t` (sound time) and the map's nearest beat at `beat` (same clock, before correction).
    public func observe(onset t: Double, strength: Float, nearestBeat beat: Double, period: Double) {
        guard strength >= 0.5 else { return }
        let d = t - beat
        guard settled else { return searchWide(d, strength: strength, period: period) }
        // then every hit within a 32nd of an 8th of the current offset keeps it fine: beats and off-beats alike; the
        // 808s on the 16ths between them fall outside
        let x = Self.wrap(d - offset, period / 2)
        guard abs(x) < 0.125 * period else { return }
        samples.append(offset + x)
        if samples.count > 32 { samples.removeFirst(samples.count - 32) }
        guard samples.count >= 8 else { return }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let dev = samples.map { abs($0 - median) }.sorted()
        spread = dev[dev.count / 2]
        confident = spread < 0.02
        guard confident else { return }
        offset += 0.3 * (median - offset)
    }

    /// `v` folded into -m/2 ..< m/2.
    static func wrap(_ v: Double, _ m: Double) -> Double { v - m * (v / m).rounded() }

    /// Where in the 8th this song's strong hits pile up, weighted by strength (the detector hears mostly the low end:
    /// kicks, 808s, claps), once 24 are in, if one place clearly wins: 35% of the weight, and 1.5x the best place 30 ms
    /// or more away. It's read from the starting guess, so the answer is the pile nearest the guess, never more than a
    /// quarter beat from it.
    private func searchWide(_ d: Double, strength: Float, period: Double) {
        let half = period / 2
        wide.append((Self.wrap(d - guess, half), strength))
        heard += 1
        guard heard >= 24, heard % 4 == 0 else { return }
        if wide.count > 128 { wide.removeFirst(wide.count - 128) }
        let total = wide.reduce(Float(0)) { $0 + $1.s }
        func weight(near c: Double) -> Float {
            wide.reduce(Float(0)) { acc, o in abs(Self.wrap(o.x - c, half)) <= 0.015 ? acc + o.s : acc }
        }
        guard let best = wide.map(\.x).max(by: { weight(near: $0) < weight(near: $1) }) else { return }
        let peak = weight(near: best)
        let rival = wide.map(\.x).filter { abs(Self.wrap($0 - best, half)) >= 0.03 }.map { weight(near: $0) }.max() ?? 0
        guard peak >= 0.35 * total, peak >= 1.5 * rival else { return }
        // the pile's own spread, unfolded around its center (a pile at the edge of the fold straddles it)
        let close = wide.map { best + Self.wrap($0.x - best, half) }.filter { abs($0 - best) <= 0.015 }.sorted()
        guard !close.isEmpty else { return }
        let center = close[close.count / 2]
        guard abs(center) <= period / 4 else { return }
        offset = guess + center
        samples = close.map { guess + $0 }
        baseline = Self.clamp(baseline + 0.25 * (offset - baseline))
        settled = true
        confident = true
    }
}
