import XCTest
@testable import RimlightCore

final class MusicSyncTests: XCTestCase {
    static let trap = SyntheticTrap()

    /// The tapped song against a recording like an earcup held to the MacBook: 177.3 ms late, thin (no lows, dull
    /// highs), 25 dB down, a desk echo, room noise, the calibration chirps on top, and the mic's sample grid offset
    /// from the tap's by a fraction of a sample.
    func testFindsTheDelayOnTheSong() {
        let song = Self.trap, sr = song.sampleRate, delay = 0.1773
        let start = 20 * song.bar                          // into the verse: 808s, claps, hats and the voice
        let ref = Array(song.samples[Int(start * sr)..<Int((start + 5.5) * sr)])
        let refStart = 5000.0
        let recStart = refStart + 0.0417 + 0.37 / sr       // the mic started a little later, off the tap's grid
        var rec = [Float](repeating: 0, count: Int(6 * sr))
        var seed: UInt64 = 11
        func noise() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: seed) >> 11) / Float(1 << 52) }
        var hp: Float = 0, lp: Float = 0, last: Float = 0
        for i in rec.indices {
            let t = recStart + Double(i) / sr - delay - refStart   // the moment of the song this sample hears
            let x = t >= 0 ? Self.sample(ref, at: t * sr) : 0
            hp = 0.97 * (hp + x - last); last = x                   // the earcup loses the lows
            lp += 0.35 * (hp - lp)                                  // and the mic the top end
            rec[i] = 0.056 * lp + 0.004 * noise()
        }
        let echo = Int(0.0062 * sr)
        for i in stride(from: rec.count - 1, through: echo, by: -1) { rec[i] += 0.5 * rec[i - echo] }
        let chirp = ChirpCalibration.chirp(sampleRate: sr)
        for k in 0..<ChirpCalibration.count {
            let at = Int((0.3 + Double(k) * ChirpCalibration.interval + 0.18) * sr)
            for (j, c) in chirp.enumerated() where at + j < rec.count { rec[at + j] += 0.2 * c }
        }
        guard let r = MusicSync.measure(reference: ref, referenceStart: refStart, recording: rec, recordingStart: recStart,
                                        sampleRate: sr) else { return XCTFail("no result") }
        print(String(format: "music sync: %.3f ms, clarity %.1f, halves %@", r.delay * 1000, r.clarity,
                     r.halves.map { String(format: "%.3f", $0 * 1000) }.joined(separator: ", ")))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.delay, delay, accuracy: 0.0003)
    }

    /// A recording of something else (the room, another song): no answer passes.
    func testUnrelatedSoundIsNotOK() {
        let song = Self.trap, sr = song.sampleRate
        let ref = Array(song.samples[Int(10 * song.bar * sr)..<Int((10 * song.bar + 5) * sr)])
        let other = Array(song.samples[Int(30 * song.bar * sr + 0.123 * sr)..<Int((30 * song.bar + 6) * sr)])
        var seed: UInt64 = 5
        let rec = other.map { x -> Float in seed = seed &* 6364136223846793005 &+ 1442695040888963407; return 0.3 * x + 0.01 * Float(Int64(bitPattern: seed) >> 11) / Float(1 << 52) }
        let r = MusicSync.measure(reference: ref, referenceStart: 0, recording: rec, recordingStart: 0, sampleRate: sr)
        XCTAssertFalse(r?.ok ?? false, "\(String(describing: r))")
    }

    private static func sample(_ x: [Float], at pos: Double) -> Float {
        let i = Int(pos), f = Float(pos - Double(i))
        guard i >= 0, i + 1 < x.count else { return 0 }
        return x[i] * (1 - f) + x[i + 1] * f
    }
}

final class TapRecorderTests: XCTestCase {
    /// Buffers go in at their timestamps: a late one leaves a gap of silence, a repeated one doesn't double the audio.
    func testPlacesBuffersByTimestamp() {
        let r = TapRecorder()
        r.arm(seconds: 1)
        let sr = 48000.0
        let buf = [Float](repeating: 1, count: 512)
        buf.withUnsafeBufferPointer { b in
            r.feed(b, rate: sr, start: 100)
            r.feed(b, rate: sr, start: 100 + 512 / sr)
            r.feed(b, rate: sr, start: 100 + 2048 / sr)        // two buffers lost
            r.feed(b, rate: sr, start: 100 + 2048 / sr)        // and one delivered twice
        }
        guard let got = r.take() else { return XCTFail() }
        XCTAssertEqual(got.start, 100)
        XCTAssertEqual(got.samples.count, 2560)
        XCTAssertEqual(got.samples[1023], 1)
        XCTAssertEqual(got.samples[1024], 0)
        XCTAssertEqual(got.samples[2047], 0)
        XCTAssertEqual(got.samples[2048], 1)
        XCTAssertNil(r.take(), "taken")
    }
}
