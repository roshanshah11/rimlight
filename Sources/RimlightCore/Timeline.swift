import Foundation

/// Where the current Spotify track is, extrapolated from the last progress report.
public struct PlaybackClock: Equatable, Sendable {
    public var progressMs: Double = 0
    public var reportedAt: Double = 0     // epoch ms when progressMs was true
    public var paused = true
    public var durationMs: Double = 0

    public init() {}
    public init(progressMs: Double, reportedAt: Double, paused: Bool, durationMs: Double = 0) {
        self.progressMs = progressMs; self.reportedAt = reportedAt; self.paused = paused; self.durationMs = durationMs
    }

    /// Take a new progress report. A small disagreement with where the clock already is (under 150 ms) is report
    /// jitter: move a quarter of the way, so the beat map doesn't jump every few seconds. A bigger one is a seek or
    /// a skip: jump. Pausing or resuming always takes the report as is.
    public mutating func update(progressMs p: Double, reportedAt at: Double, paused nowPaused: Bool) {
        if !paused, !nowPaused {
            let expected = position(at: at)
            let diff = p - expected
            if abs(diff) < 150 {
                progressMs = expected + 0.25 * diff
                reportedAt = at
                return
            }
        }
        progressMs = p
        reportedAt = at
        paused = nowPaused
    }

    /// Track position in ms at epoch-ms `now`.
    public func position(at now: Double) -> Double {
        guard !paused else { return progressMs }
        let p = progressMs + max(0, now - reportedAt)
        return durationMs > 0 ? min(p, durationMs) : p
    }
}

/// Spotify's beat map for one track (seconds of track time), with downbeats marked from the bar starts.
public struct BeatGrid: Equatable, Sendable {
    public let uri: String
    public let tempo: Double
    public let beats: [Double]
    public let confidence: [Float]
    public let downbeat: [Bool]

    public init(uri: String, tempo: Double, beats: [Double], confidence: [Float], bars: [Double]) {
        self.uri = uri
        self.tempo = tempo
        let order = beats.indices.sorted { beats[$0] < beats[$1] }
        self.beats = order.map { beats[$0] }
        self.confidence = order.map { $0 < confidence.count ? confidence[$0] : 1 }
        let sortedBars = bars.sorted()
        var marks = [Bool](repeating: false, count: order.count)
        var j = 0
        for (i, t) in self.beats.enumerated() {
            while j < sortedBars.count, sortedBars[j] < t - 0.06 { j += 1 }
            if j < sortedBars.count, abs(sortedBars[j] - t) <= 0.06 { marks[i] = true }
        }
        downbeat = marks
    }

    /// Index of the last beat at or before `t` seconds.
    public func lastBeat(atOrBefore t: Double) -> Int? {
        var lo = 0, hi = beats.count - 1, ans: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if beats[mid] <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    /// Beat envelope at track time `t`: 1 right on a beat, decaying with time constant `tau` seconds.
    /// Downbeats hit full strength, other beats 0.75, both scaled by Spotify's confidence (floored at 0.4).
    public func pulse(at t: Double, tau: Double) -> Float {
        guard let i = lastBeat(atOrBefore: t) else { return 0 }
        let age = t - beats[i]
        guard age < tau * 6 else { return 0 }
        let strength: Float = (downbeat[i] ? 1 : 0.75) * max(0.4, min(1, confidence[i] * 1.6))
        return strength * Float(exp(-age / tau))
    }
}

/// Beat pulses from live audio detection, scheduled at the moment they become audible.
public struct PulseTrain: Sendable {
    private var hits: [(time: Double, strength: Float)] = []
    public init() {}

    public mutating func add(at time: Double, strength: Float) {
        hits.append((time, strength))
        if hits.count > 16 { hits.removeFirst(hits.count - 16) }
    }

    /// Envelope at `now` (same clock as `add`). Hits in the future are ignored until they arrive.
    public mutating func value(at now: Double, tau: Double) -> Float {
        hits.removeAll { now - $0.time > tau * 6 }
        var v: Float = 0
        for h in hits where h.time <= now {
            v = max(v, h.strength * Float(exp(-(now - h.time) / tau)))
        }
        return v
    }
}

public struct LyricLine: Codable, Equatable, Sendable {
    public var t: Double      // start, ms
    public var w: String      // words
    public init(t: Double, w: String) { self.t = t; self.w = w }
}

/// Line-synced lyrics for one track.
public struct LyricsTimeline: Equatable, Sendable {
    public let uri: String
    public let lines: [LyricLine]

    public init(uri: String, lines: [LyricLine]) {
        self.uri = uri
        self.lines = lines.sorted { $0.t < $1.t }   // empty lines stay: they end the previous line
    }

    /// Index of the line being sung at `ms`, nil before the first line.
    public func index(at ms: Double) -> Int? {
        var lo = 0, hi = lines.count - 1, ans: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].t <= ms { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    /// The current line's words, or nil for instrumental gaps (Spotify marks them with "♪" or empty words).
    public func line(at ms: Double) -> String? {
        guard let i = index(at: ms) else { return nil }
        let w = lines[i].w.trimmingCharacters(in: .whitespacesAndNewlines)
        return w.isEmpty || w == "♪" ? nil : w
    }

    public func next(after ms: Double) -> String? {
        let i = (index(at: ms) ?? -1) + 1
        guard i < lines.count else { return nil }
        let w = lines[i].w.trimmingCharacters(in: .whitespacesAndNewlines)
        return w.isEmpty || w == "♪" ? nil : w
    }
}
