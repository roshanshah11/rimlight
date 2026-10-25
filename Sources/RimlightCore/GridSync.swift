import Foundation

/// Spotify's beat map on the sound clock. Spotify reports its track position (PlaybackClock, on the epoch-ms clock);
/// the tap hears the sound (host seconds). GridSync converts between the two, learns the offset between Spotify's
/// position and the audio it actually plays from the kicks the tap hears (GridCalibrator), and hands out each beat of
/// the map at the moment it sounds.
public final class GridSync {
    public let calibrator: GridCalibrator
    public private(set) var grid: BeatGrid?
    private var lastPos: Double?

    /// Debug: every onset matched to the map, as (sound time, strength, onset minus the uncorrected map beat, period).
    public var onObserve: ((Double, Float, Double, Double) -> Void)?

    public init(calibrator: GridCalibrator = GridCalibrator()) { self.calibrator = calibrator }

    public func setGrid(_ g: BeatGrid?) { grid = g; lastPos = nil }

    /// A moment on both clocks at once (read them together).
    public struct Now: Sendable {
        public var host: Double, epochMs: Double
        public init(host: Double, epochMs: Double) { self.host = host; self.epochMs = epochMs }
    }

    /// Spotify's position (seconds) for sound time `t`, uncorrected.
    public func rawTrackTime(forSound t: Double, clock: PlaybackClock, now: Now) -> Double {
        clock.position(at: now.epochMs) / 1000 + (t - now.host)
    }

    /// The corrected track position heard at sound time `t`.
    public func trackTime(forSound t: Double, clock: PlaybackClock, now: Now) -> Double {
        rawTrackTime(forSound: t - calibrator.offset, clock: clock, now: now)
    }

    /// When track position `p` sounds, corrected.
    public func soundTime(forTrack p: Double, clock: PlaybackClock, now: Now) -> Double {
        now.host + (p - clock.position(at: now.epochMs) / 1000) + calibrator.offset
    }

    /// A kick the tap heard at sound time `t`: match it to the map's nearest beat and learn the offset.
    public func observe(onset t: Double, strength: Float, clock: PlaybackClock, now: Now) {
        guard let g = grid, !clock.paused else { return }
        let period = 60 / max(g.tempo, 1)
        // where Spotify says the track was when this sounded, if the current correction is right
        let p = trackTime(forSound: t, clock: clock, now: now)
        guard let i = g.lastBeat(atOrBefore: p + period / 2) else { return }
        // the map beat's sound time without the correction: the calibrator learns the whole offset
        let uncorrected = soundTime(forTrack: g.beats[i], clock: clock, now: now) - calibrator.offset
        calibrator.observe(onset: t, strength: strength, nearestBeat: uncorrected, period: period)
        onObserve?(t, strength, t - uncorrected, period)
    }

    public struct Beat: Equatable, Sendable {
        public var sound: Double, track: Double, strength: Float, downbeat: Bool
    }

    /// Map beats that sound up to sound time `t` (since the last call). A seek, or the first call, re-anchors.
    public func beats(through t: Double, clock: PlaybackClock, now: Now) -> [Beat] {
        guard let g = grid, !clock.paused else { lastPos = nil; return [] }
        let pos = trackTime(forSound: t, clock: clock, now: now)
        defer { lastPos = pos }
        guard let last = lastPos, pos > last, pos - last < 2 else { return [] }
        return g.beats.indices.filter { g.beats[$0] > last && g.beats[$0] <= pos }.map { i in
            Beat(sound: soundTime(forTrack: g.beats[i], clock: clock, now: now), track: g.beats[i],
                 strength: max(0.4, min(1, g.confidence[i] * 1.6)), downbeat: g.downbeat[i])
        }
    }
}
