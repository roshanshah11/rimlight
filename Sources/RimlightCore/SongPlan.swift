import Foundation

/// The parts of Spotify's audio analysis the show uses (track time in seconds, loudness in dB).
public struct SongAnalysis: Equatable, Sendable {
    public struct SongSection: Equatable, Sendable {
        public var start: Double, duration: Double, loudness: Double
        public init(start: Double, duration: Double, loudness: Double) {
            self.start = start; self.duration = duration; self.loudness = loudness
        }
    }
    public var tempo: Double
    public var beats: [Double]
    public var bars: [Double]
    public var sections: [SongSection]
    public var beatLoudness: [Double]      // one per beat: the loudest moment in it

    public init(tempo: Double, beats: [Double], bars: [Double], sections: [SongSection], beatLoudness: [Double]) {
        self.tempo = tempo; self.beats = beats; self.bars = bars; self.sections = sections; self.beatLoudness = beatLoudness
    }
}

/// The show planned ahead from the analysis, the way rekordbox plans lighting from its phrase analysis: a look per
/// bar, the drops, the builds that set them up, and a blackout on the last half beat before each drop.
public struct SongPlan: Equatable, Sendable {
    public enum Cue: Equatable, Sendable {
        case quiet, groove, drop
        case build(progress: Float)       // 0 at the first bar of the build, 1 at the last
        public var section: Section {
            switch self {
            case .quiet: return .quiet
            case .groove: return .groove
            case .drop: return .drop
            case .build: return .build
            }
        }
    }

    public let barStarts: [Double]
    public let cues: [Cue]
    public let drops: [Double]            // track times of each drop's first downbeat
    public let blackouts: [Range<Double>]
    /// The part of each blackout where the music is actually silent (empty when the drop just hits): rap uses only
    /// these, so a hook doesn't get a blackout the song doesn't have.
    public let gaps: [Range<Double>]
    /// Bars of the hook, found from the lyrics (HookFinder), snapped to the nearest bar lines.
    public let hooks: [Range<Int>]
    /// Each bar's energy within the song, 0...1.
    public let energy: [Double]

    /// The cue for the bar playing at track time `t`.
    public func cue(at t: Double) -> Cue? {
        guard let i = barIndex(at: t) else { return nil }
        return cues[i]
    }

    public func barIndex(at t: Double) -> Int? {
        var lo = 0, hi = barStarts.count - 1, ans: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if barStarts[mid] <= t + 0.03 { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    public func inBlackout(_ t: Double) -> Bool { blackouts.contains { $0.contains(t) } }
    public func inGap(_ t: Double) -> Bool { gaps.contains { $0.contains(t) } }
    public func inHook(_ t: Double) -> Bool {
        guard let b = barIndex(at: t) else { return false }
        return hooks.contains { $0.contains(b) }
    }

    /// `hooks`: the hook's occurrences in track time (HookFinder on the synced lyrics), if any.
    public static func make(_ a: SongAnalysis, hooks hookTimes: [Range<Double>] = []) -> SongPlan? {
        guard a.bars.count >= 4, a.beats.count == a.beatLoudness.count, !a.beats.isEmpty else { return nil }
        // beat energy 0...1 within this track (10th to 95th percentile of loudness)
        let sorted = a.beatLoudness.sorted()
        let lo = sorted[sorted.count / 10], hi = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        let span = max(3, hi - lo)
        let beatEnergy = a.beatLoudness.map { min(1, max(0, ($0 - lo) / span)) }

        let bars = a.bars
        func barEnergy(_ i: Int) -> Double {
            let s = bars[i], e = i + 1 < bars.count ? bars[i + 1] : s + 4 * 60 / max(a.tempo, 1)
            let v = a.beats.indices.filter { a.beats[$0] >= s - 0.02 && a.beats[$0] < e - 0.02 }.map { beatEnergy[$0] }
            return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
        }
        // blend each bar with its section, so one quiet bar inside a chorus doesn't break the look
        let secEnergy: [Double] = a.sections.map { s in
            let idx = bars.indices.filter { bars[$0] >= s.start - 0.05 && bars[$0] < s.start + s.duration - 0.05 }
            return idx.isEmpty ? 0 : idx.map(barEnergy).reduce(0, +) / Double(idx.count)
        }
        let energy: [Double] = bars.indices.map { i in
            let own = barEnergy(i)
            guard let si = a.sections.lastIndex(where: { $0.start <= bars[i] + 0.05 }) else { return own }
            return 0.35 * secEnergy[si] + 0.65 * own
        }

        if ProcessInfo.processInfo.environment["RIM_PLAN_DEBUG"] != nil {
            print("bar energy:", energy.map { String(Int(($0 * 9.99).rounded(.down))) }.joined())
            print(String(format: "beat loudness p10 %.1f p95 %.1f", lo, hi))
        }
        let ranked = energy.sorted()
        let top = ranked[min(ranked.count - 1, ranked.count * 9 / 10)]
        var cues: [Cue] = energy.map { e in e >= max(0.55, top - 0.12) ? .drop : (e < 0.35 ? .quiet : .groove) }
        // a drop lasts at least 4 bars; shorter loud patches are groove
        var i = 0
        while i < cues.count {
            guard cues[i] == .drop else { i += 1; continue }
            var j = i
            while j < cues.count, cues[j] == .drop { j += 1 }
            if j - i < 4 { for k in i..<j { cues[k] = .groove } }
            i = j
        }
        // drops start where a drop follows something clearly quieter
        var drops: [Int] = []
        for k in 1..<cues.count where cues[k] == .drop && cues[k - 1] != .drop {
            let before = energy[max(0, k - 2)..<k].reduce(0, +) / Double(min(2, k))
            if energy[k] - before >= 0.15 { drops.append(k) }
        }
        // A drop is a moment, not a level: flat-mastered tracks sit near their own peak for minutes (Mac Miller's
        // "Woods" read as one 3-minute drop). Only a run that starts with a jump is a drop, and only for its first
        // 8 bars; the rest of a loud stretch is groove. Contrast is what makes the next one land.
        var k = 0
        while k < cues.count {
            guard cues[k] == .drop else { k += 1; continue }
            var j = k
            while j < cues.count, cues[j] == .drop { j += 1 }
            let keep = drops.contains(k) ? min(j, k + 8) : k
            for x in keep..<j { cues[x] = .groove }
            k = j
        }
        // the 4 bars before each drop build to it (8 when the energy climbs across them)
        for d in drops {
            let rising = d >= 8 && energy[d - 1] - energy[d - 8] > 0.15
            let n = rising ? 8 : 4
            let first = max(0, d - n)
            let start = (first..<d).last(where: { cues[$0] == .drop }).map { $0 + 1 } ?? first
            let len = d - start
            guard len > 0 else { continue }
            for k in start..<d { cues[k] = .build(progress: len == 1 ? 1 : Float(k - start) / Float(len - 1)) }
        }
        let beat = 60 / max(a.tempo, 1)
        let dropTimes = drops.map { bars[$0] }
        // the blackout is the last half beat before the drop, or every silent beat leading into it
        // (20 dB under the drop), whichever is longer
        var gaps: [Range<Double>] = []
        let blackouts: [Range<Double>] = dropTimes.map { d in
            var start = d - beat / 2
            defer { if start < d - beat / 2 - 0.01 { gaps.append(start..<d) } }
            let dropLoud = a.beats.indices.filter { a.beats[$0] >= d - 0.02 && a.beats[$0] < d + 4 * beat }
                .map { a.beatLoudness[$0] }
            let ref = dropLoud.isEmpty ? (a.beatLoudness.max() ?? 0) : dropLoud.reduce(0, +) / Double(dropLoud.count)
            var i = (a.beats.lastIndex { $0 < d - 0.02 }) ?? -1
            while i >= 0, a.beatLoudness[i] < ref - 20, d - a.beats[i] <= 8 * beat {
                start = min(start, a.beats[i])
                i -= 1
            }
            return start..<d
        }
        // the hook, from the first bar line nearest its first line to the bar line nearest its end (a rapper's
        // pickup starts before the downbeat); at least two bars
        func nearestBar(_ t: Double) -> Int {
            bars.indices.min { abs(bars[$0] - t) < abs(bars[$1] - t) } ?? 0
        }
        let hooks: [Range<Int>] = hookTimes.compactMap { r in
            let a = nearestBar(r.lowerBound), b = r.upperBound > bars[bars.count - 1] ? bars.count : nearestBar(r.upperBound)
            return b - a >= 2 ? a..<b : nil
        }
        return SongPlan(barStarts: bars, cues: cues, drops: dropTimes, blackouts: blackouts, gaps: gaps, hooks: hooks, energy: energy)
    }
}
