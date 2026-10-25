import Foundation

/// A phase-locked beat clock for live audio. The detector reports a kick ~30 ms after it sounds; lighting on the
/// report is always late. The clock instead learns the tempo and the beat phase from the kicks and announces each
/// beat at its predicted time, so the light lands with the sound. Off-beat onsets (claps, hats) don't move it; it
/// keeps time through a missed kick or a short gap, and lets go after two bars with nothing on the grid.
public final class BeatClock {
    public private(set) var period: Double?
    public private(set) var anchor: Double?        // the time of one beat on the grid
    public private(set) var locked = false
    public var lastError: Double = 0               // seconds, the last kick's distance from the grid
    private var errors: [Double] = []
    /// Median distance of the last 16 on-grid kicks from where the clock predicted them (seconds).
    public var typicalError: Double? {
        guard errors.count >= 6 else { return nil }
        return errors.map(abs).sorted()[errors.count / 2]
    }

    private var hits = 0, misses = 0
    private var recentOnsets: [Double] = []
    private var strong: [(t: Double, s: Float)] = []    // the last ~4 s of onsets with their strength
    private var lastOnTime = -10.0
    private var unlockedSince: Double?

    public init() {}

    public func reset() {
        period = nil; anchor = nil; locked = false
        hits = 0; misses = 0; recentOnsets = []; strong = []; errors = []
    }

    /// Tempo from the detector's autocorrelation, when it has one. Snaps the period if it's far off.
    public func setTempo(_ bpm: Double?) {
        guard let bpm, bpm >= 60, bpm <= 200 else { return }
        let p = 60 / bpm
        if let cur = period {
            if abs(cur - p) / p > 0.04 { period = p }
        } else {
            period = p
        }
    }

    /// A detected onset at `t` (its own time, not the report's). Only strong onsets steer the clock.
    /// How long the clock has heard onsets without locking (0 while locked). Past ~4 s the caller can fall back to
    /// lighting on the detector's reports.
    public func unlockedFor(at t: Double) -> Double {
        locked ? 0 : unlockedSince.map { t - $0 } ?? 0
    }

    public func onset(at t: Double, strength: Float) {
        if locked { unlockedSince = nil } else if unlockedSince == nil { unlockedSince = t }
        recentOnsets.append(t)
        if recentOnsets.count > 16 { recentOnsets.removeFirst(recentOnsets.count - 16) }
        strong.append((t, strength))
        strong.removeAll { t - $0.t > 4 }
        guard strength >= 0.45 else { return }
        if period == nil, recentOnsets.count >= 5 {
            let gaps = zip(recentOnsets, recentOnsets.dropFirst()).map { $1 - $0 }.filter { $0 > 0.3 && $0 < 1 }
            if gaps.count >= 3 { period = gaps.sorted()[gaps.count / 2] }
        }
        guard let p = period else { return }
        guard let a0 = anchor else { anchor = t; return }
        // which grid do the strongest onsets fall on? Every recent strong onset is a candidate beat position;
        // the kicks outscore the off-beat bass and hats. Switch only on a clear margin, so it doesn't wobble.
        var a = a0
        if strong.count >= 6 {
            let current = score(anchor: a0, period: p)
            if let best = strong.filter({ $0.s >= 0.45 }).map({ ($0.t, score(anchor: $0.t, period: p)) }).max(by: { $0.1 < $1.1 }),
               best.1 > current * 1.3 {
                a = best.0
                anchor = a
                hits = 0
                locked = false
            }
        }
        let k = ((t - a) / p).rounded()
        let err = t - (a + k * p)
        if abs(err) < 0.18 * p {
            // pull the phase most of the way, the period a little
            anchor = a + k * p + 0.4 * err
            if k != 0 { period = p + 0.08 * err / max(1, abs(k)) }
            lastError = err
            errors.append(err)
            if errors.count > 16 { errors.removeFirst(errors.count - 16) }
            hits += 1
            misses = 0
            if hits >= 4, abs(err) < 0.04 { locked = true }
        } else {
            misses += 1
            if misses >= 6 {
                // off the grid for a while: re-seed on this onset
                anchor = t
                hits = 0
                locked = false
            }
        }
    }

    private func score(anchor a: Double, period p: Double) -> Float {
        strong.reduce(0) { acc, o in
            let k = ((o.t - a) / p).rounded()
            return abs(o.t - (a + k * p)) < 0.1 * p ? acc + o.s * o.s : acc
        }
    }

    /// Predicted beats in (from, to], only while locked and the grid hasn't gone quiet for two bars.
    public func beats(after from: Double, through to: Double, lastOnset: Double) -> [Double] {
        guard locked, let p = period, let a = anchor, to - lastOnset < 8 * p else { return [] }
        var out: [Double] = []
        var k = ((from - a) / p).rounded(.down)
        while true {
            let t = a + k * p
            if t > to { break }
            if t > from { out.append(t) }
            k += 1
        }
        return out
    }
}
