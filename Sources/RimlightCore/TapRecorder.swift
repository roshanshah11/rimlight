import Foundation

/// The tapped song, kept for a few seconds while a calibration runs (fed on the tap's queue). Each buffer goes in at
/// its own timestamp, so a dropped buffer leaves a gap instead of shifting everything after it.
public final class TapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var armedUntil = 0
    private var samples: [Float] = []
    private var start: Double?
    private var rate = 48000.0

    public init() {}

    public func arm(seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        samples = []
        samples.reserveCapacity(Int(seconds * 48000) + 8192)
        start = nil
        armedUntil = Int(seconds * 48000)
    }

    public func feed(_ buf: UnsafeBufferPointer<Float>, rate r: Double, start t: Double) {
        lock.lock(); defer { lock.unlock() }
        guard armedUntil > 0 else { return }
        if start == nil { start = t; rate = r }
        guard let s = start, r == rate else { armedUntil = 0; return }
        let at = Int(((t - s) * rate).rounded())
        if at > samples.count + 2 { samples += [Float](repeating: 0, count: at - samples.count) }
        else if at < samples.count - 2 { samples.removeLast(min(samples.count, samples.count - max(0, at))) }
        samples.append(contentsOf: buf)
        if samples.count >= armedUntil { armedUntil = 0 }
    }

    /// What was recorded, and stop.
    public func take() -> (samples: [Float], start: Double, rate: Double)? {
        lock.lock(); defer { lock.unlock() }
        armedUntil = 0
        defer { samples = []; start = nil }
        return start.map { (samples, $0, rate) }
    }
}
