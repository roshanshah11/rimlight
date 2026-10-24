import XCTest
@testable import RimlightCore

/// Synthetic mixes: a decaying 55 Hz kick on every beat, hi-hat noise on the off-beats, a sustained pad, noise floor.
private func mix(bpm: Double, seconds: Double, sr: Double = 48000, kickGain: Float = 0.8, seed: UInt64 = 7) -> (samples: [Float], kicks: [Double]) {
    var rng = seed
    func noise() -> Float {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: rng >> 11) % 2_000_000) / 1_000_000 - 1
    }
    let n = Int(seconds * sr)
    var out = [Float](repeating: 0, count: n)
    let period = 60 / bpm
    var kicks: [Double] = []
    var t = 0.25
    while t < seconds { kicks.append(t); t += period }
    for (i, _) in out.enumerated() {
        let time = Double(i) / sr
        var s: Float = 0.02 * noise()
        s += 0.08 * Float(sin(2 * .pi * 220 * time) + 0.5 * sin(2 * .pi * 330 * time))   // pad
        out[i] = s
    }
    for k in kicks {
        let start = Int(k * sr)
        for j in 0..<Int(0.18 * sr) where start + j < n {
            let tt = Double(j) / sr
            let f = 55 + 90 * exp(-tt * 40)                       // pitch drop
            out[start + j] += kickGain * Float(exp(-tt * 18) * sin(2 * .pi * f * tt))
        }
        let hat = Int((k + period / 2) * sr)
        for j in 0..<Int(0.03 * sr) where hat + j < n {
            out[hat + j] += 0.12 * noise() * Float(exp(-Double(j) / sr * 120))
        }
    }
    return (out, kicks)
}

private func feed(_ d: BeatDetector, _ samples: [Float], chunk: Int = 471) -> [BeatEvent] {
    var beats: [BeatEvent] = []
    var i = 0
    while i < samples.count {
        let end = min(samples.count, i + chunk)
        beats += samples[i..<end].withUnsafeBufferPointer { d.process($0) }
        i = end
    }
    return beats
}

final class BeatDetectorTests: XCTestCase {
    func testFindsKicksAt120() {
        let (s, kicks) = mix(bpm: 120, seconds: 12)
        let d = BeatDetector(sampleRate: 48000)
        let beats = feed(d, s)
        let hits = kicks.filter { k in beats.contains { abs($0.time - k) < 0.05 } }.count
        let falseHits = beats.filter { b in !kicks.contains { abs(b.time - $0) < 0.05 } }.count
        XCTAssertGreaterThanOrEqual(Double(hits) / Double(kicks.count), 0.9, "recall")
        XCTAssertLessThanOrEqual(falseHits, kicks.count / 10, "false beats")
        XCTAssertEqual(d.tempo ?? 0, 120, accuracy: 2.5)
    }

    func testTempoAcrossRange() {
        for bpm in [92.0, 128.0, 150.0] {
            let d = BeatDetector(sampleRate: 48000)
            _ = feed(d, mix(bpm: bpm, seconds: 10).samples)
            let t = d.tempo ?? 0
            // octave errors are acceptable for the light (it pulses on every beat either way), off-tempo is not
            let ok = [bpm, bpm / 2, bpm * 2].contains { abs(t - $0) <= 3 }
            XCTAssertTrue(ok, "bpm \(bpm) estimated \(t)")
        }
    }

    func testOnsetTimingIsAccurate() {
        let (s, kicks) = mix(bpm: 100, seconds: 8)
        let d = BeatDetector(sampleRate: 48000)
        let beats = feed(d, s)
        var errs: [Double] = []
        for k in kicks {
            let offsets: [Double] = beats.map { $0.time - k }
            if let nearest = offsets.min(by: { abs($0) < abs($1) }), abs(nearest) < 0.1 { errs.append(nearest) }
        }
        XCTAssertFalse(errs.isEmpty)
        let mean = errs.reduce(0, +) / Double(errs.count)
        XCTAssertLessThan(abs(mean), 0.03, "mean onset error \(mean)")
    }

    func testSilenceHasNoBeats() {
        let d = BeatDetector(sampleRate: 48000)
        let beats = feed(d, [Float](repeating: 0, count: 48000 * 4))
        XCTAssertTrue(beats.isEmpty)
        XCTAssertTrue(d.features.silent)
        XCTAssertEqual(d.features.energy, 0)
    }

    func testQuietSongStillDetected() {
        let (loud, kicks) = mix(bpm: 120, seconds: 10)
        let quiet = loud.map { $0 * 0.05 }
        let d = BeatDetector(sampleRate: 48000)
        let beats = feed(d, quiet)
        let hits = kicks.filter { k in beats.contains { abs($0.time - k) < 0.05 } }.count
        XCTAssertGreaterThanOrEqual(Double(hits) / Double(kicks.count), 0.85)
    }

    func testEnergyRisesWithMusic() {
        let d = BeatDetector(sampleRate: 48000)
        _ = feed(d, mix(bpm: 120, seconds: 3).samples)
        XCTAssertFalse(d.features.silent)
        XCTAssertGreaterThan(d.features.energy, 0.05)
    }

    func testLatencyIsUnderFiftyMs() {
        let d = BeatDetector(sampleRate: 48000)
        XCTAssertLessThan(d.detectionLatency, 0.05)
    }
}
