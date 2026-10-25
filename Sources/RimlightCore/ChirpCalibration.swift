import Accelerate
import Foundation

/// Measures how long sound takes to come out of an output, the way Rock Band's guitar and Apple TV's Wireless Audio
/// Sync do: play known chirps, hear them on a microphone, and time each one. Rimlight plays them through the current
/// output (Bluetooth headphones held against the MacBook) and listens on the MacBook's own mic, so the headphones'
/// mic, and the headset mode it would force, is never used.
public enum ChirpCalibration {
    public static let count = 8
    public static let interval = 0.5          // seconds between chirps (Rock Band: one every half second)
    public static let length = 0.04           // each chirp, seconds
    /// How late after its start a chirp may be heard: short of the next chirp (interval - length), or a fast
    /// output (the built-in speakers, 15 ms) hears the next chirp in the same window as a rival.
    public static let searchWindow = 0.42

    /// A rising sweep from 1.5 to 6 kHz, faded in and out: high enough to get through an earcup's leakage and above
    /// room rumble, sharp enough in time to place within a fraction of a millisecond.
    public static func chirp(sampleRate: Double) -> [Float] {
        let n = Int(length * sampleRate)
        let f0 = 1500.0, f1 = 6000.0
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * (f0 * t + (f1 - f0) * t * t / (2 * length))
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            return Float(sin(phase) * w)
        }
    }

    public struct Result: Equatable, Sendable {
        public var latency: Double        // median seconds from playing a chirp to hearing it
        public var spread: Double         // median absolute deviation of the timings, seconds
        public var heard: Int             // chirps found, of `count`
        public var timings: [Double]
        public var ok: Bool { heard >= 5 && spread < 0.004 }
    }

    /// Find each chirp in a recording. `played`: when each chirp started (host seconds); `recording`: mono samples
    /// whose first sample was captured at `recordingStart` (host seconds). Each chirp is looked for in the
    /// `searchWindow` after it played, by matched filter; one counts if its peak stands well clear of the window
    /// (8x the median, and twice anything more than 20 ms away), so a door slam or a voice doesn't pass for it. Of the
    /// peaks within 6 dB of the strongest, the earliest is the chirp: the direct sound arrives before its echoes,
    /// even when an echo off the desk comes in louder.
    public static func measure(played: [Double], recording: [Float], recordingStart: Double, sampleRate: Double) -> Result {
        let template = chirp(sampleRate: sampleRate)
        let tn = template.count
        var timings: [Double] = []
        for p in played {
            let from = Int(((p - recordingStart) * sampleRate).rounded(.down))
            let lags = Int(searchWindow * sampleRate)
            guard from >= 0, from + lags + tn <= recording.count else { continue }
            var corr = [Float](repeating: 0, count: lags)
            recording.withUnsafeBufferPointer { r in
                vDSP_conv(r.baseAddress! + from, 1, template, 1, &corr, 1, vDSP_Length(lags), vDSP_Length(tn))
            }
            var env = corr.map { abs($0) }
            // the envelope peak, smoothed over half a millisecond so the sweep's own oscillation doesn't jitter it
            let half = max(1, Int(0.00025 * sampleRate))
            var smooth = [Float](repeating: 0, count: lags)
            var acc: Float = 0
            for i in 0..<lags {
                acc += env[i]
                if i >= 2 * half + 1 { acc -= env[i - 2 * half - 1] }
                if i >= half { smooth[i - half] = acc }
            }
            env = smooth
            guard let top = env.indices.max(by: { env[$0] < env[$1] }) else { continue }
            let sorted = env.sorted()
            let median = sorted[sorted.count / 2]
            guard env[top] > 8 * max(median, 1e-9) else { continue }
            let far = Int(0.02 * sampleRate)
            let rival = env.indices.filter { abs($0 - top) > far }.map { env[$0] }.max() ?? 0
            guard env[top] > 2 * rival else { continue }
            // the earliest peak (the highest point within a millisecond either side) at least half the strongest
            let near = Int(0.001 * sampleRate)
            let peak = (max(0, top - far)...top).first { i in
                env[i] >= 0.5 * env[top] && env[max(0, i - near)...min(lags - 1, i + near)].allSatisfy { $0 <= env[i] }
            } ?? top
            // refine to the strongest raw correlation within the smoothed peak, then between samples (parabola)
            let lo = max(1, peak - half), hi = min(lags - 2, peak + half)
            var best = lo
            for i in lo...hi where abs(corr[i]) > abs(corr[best]) { best = i }
            let a = abs(corr[best - 1]), b = abs(corr[best]), c = abs(corr[best + 1])
            let den = a - 2 * b + c
            let frac = den != 0 ? Double(max(-0.5, min(0.5, 0.5 * (a - c) / den))) : 0
            let heardAt = recordingStart + (Double(from + best) + frac) / sampleRate
            timings.append(heardAt - p)
        }
        guard !timings.isEmpty else { return Result(latency: 0, spread: 1, heard: 0, timings: []) }
        let sorted = timings.sorted()
        let median = sorted[sorted.count / 2]
        let dev = timings.map { abs($0 - median) }.sorted()
        return Result(latency: median, spread: dev[dev.count / 2], heard: timings.count, timings: timings)
    }
}
