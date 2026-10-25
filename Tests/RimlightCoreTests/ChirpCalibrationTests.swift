import XCTest
@testable import RimlightCore

final class ChirpCalibrationTests: XCTestCase {
    /// A recording like an earcup held to the MacBook: each chirp arrives 173.4 ms late, 30 dB down, with a room
    /// echo, under steady noise, one chirp lost and a loud knock in another chirp's window.
    func testFindsTheDelayThroughNoiseEchoesAndAKnock() {
        let sr = 48000.0, delay = 0.1734
        let chirp = ChirpCalibration.chirp(sampleRate: sr)
        let start = 1000.0                                   // host time of the first recorded sample
        let played = (0..<ChirpCalibration.count).map { start + 0.3 + Double($0) * ChirpCalibration.interval }
        var rec = [Float](repeating: 0, count: Int(5.5 * sr))
        var seed: UInt64 = 7
        func noise() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: seed) >> 11) / Float(1 << 52) }
        for i in rec.indices { rec[i] = 0.004 * noise() }
        for (k, p) in played.enumerated() where k != 3 {    // the 4th chirp never arrives
            let at = Int(((p + delay - start) * sr).rounded())
            for (j, x) in chirp.enumerated() {
                rec[at + j] += 0.03 * x
                rec[at + j + Int(0.011 * sr)] += 0.012 * x   // an echo 11 ms later
            }
        }
        let knock = Int(((played[5] + 0.05 - start) * sr).rounded())
        for j in 0..<400 { rec[knock + j] += 0.5 * Float(exp(-Double(j) / 60)) * noise() }
        let r = ChirpCalibration.measure(played: played, recording: rec, recordingStart: start, sampleRate: sr)
        print(String(format: "chirps: heard %d of %d, latency %.2f ms, spread %.3f ms", r.heard, played.count, r.latency * 1000, r.spread * 1000))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.heard, 7)
        XCTAssertEqual(r.latency, delay, accuracy: 0.0002)
    }

    /// The built-in speakers: 15 ms, so the next chirp is in sight of each window; and an echo off the desk 4 ms
    /// later, louder than the direct sound. Every chirp is timed by its direct sound.
    func testFastOutputAndALoudEcho() {
        let sr = 48000.0, delay = 0.0154
        let chirp = ChirpCalibration.chirp(sampleRate: sr)
        let played = (0..<ChirpCalibration.count).map { 0.35 + Double($0) * ChirpCalibration.interval }
        var rec = [Float](repeating: 0, count: Int(5.4 * sr))
        for p in played {
            let at = Int(((p + delay) * sr).rounded())
            for (j, x) in chirp.enumerated() {
                rec[at + j] += 0.02 * x
                rec[at + j + Int(0.004 * sr)] += 0.03 * x
            }
        }
        let r = ChirpCalibration.measure(played: played, recording: rec, recordingStart: 0, sampleRate: sr)
        XCTAssertEqual(r.heard, ChirpCalibration.count)
        XCTAssertEqual(r.latency, delay, accuracy: 0.0002)
        XCTAssertLessThan(ChirpCalibration.searchWindow + ChirpCalibration.length, ChirpCalibration.interval)
    }

    /// Silence or plain noise: nothing passes for a chirp.
    func testNothingHeardIsNotOK() {
        let sr = 48000.0
        var seed: UInt64 = 3
        let rec = (0..<Int(5 * sr)).map { _ -> Float in seed = seed &* 6364136223846793005 &+ 1442695040888963407; return 0.01 * Float(Int64(bitPattern: seed) >> 11) / Float(1 << 52) }
        let played = (0..<ChirpCalibration.count).map { 0.3 + Double($0) * ChirpCalibration.interval }
        let r = ChirpCalibration.measure(played: played, recording: rec, recordingStart: 0, sampleRate: sr)
        XCTAssertFalse(r.ok, "heard \(r.heard)")
    }
}
