import XCTest
@testable import RimlightCore

final class CalibrationTests: XCTestCase {
    /// Spotify's map is 70 ms early against the real sound: the calibrator should find +70 ms from the kicks.
    func testRecoversASkewedBeatMap() {
        let s = TimingTests.song
        let skew = 0.070
        let map = s.beats.map { $0 - skew }
        let det = BeatDetector(sampleRate: s.sampleRate)
        let cal = GridCalibrator()
        s.samples.withUnsafeBufferPointer { all in
            var i = 0
            while i + 512 <= all.count {
                for b in det.process(UnsafeBufferPointer(rebasing: all[i..<(i + 512)])) {
                    if let near = map.min(by: { abs($0 + cal.offset - b.time) < abs($1 + cal.offset - b.time) }) {
                        cal.observe(onset: b.time, strength: b.strength, nearestBeat: near, period: s.beat)
                    }
                }
                _ = det.drainBeats()
                i += 512
            }
        }
        print(String(format: "calibrated offset %.1f ms (true %.1f), spread %.1f ms", cal.offset * 1000, skew * 1000, cal.spread * 1000))
        XCTAssertTrue(cal.confident)
        XCTAssertEqual(cal.offset, skew, accuracy: 0.005)
    }

    /// Three songs in a row whose beat maps sit +30, -50 and +5 ms off their kicks: each one's offset is found
    /// within 8 ms by the 8th bar of kicks, and one song's offset never leaks into the next.
    func testLearnsEachSongOnItsOwn() {
        let s = TimingTests.song
        let cal = GridCalibrator(offset: 0.028)   // what calibration.json held on 2026-10-24
        let firstKick = s.kickBeats.first ?? 0
        for skew in [0.030, -0.050, 0.005] {
            cal.newTrack()
            let map = s.beats.map { $0 - skew }
            let det = BeatDetector(sampleRate: s.sampleRate)
            var settledAt: Double?
            var errorAtBar8 = Double.infinity
            s.samples.withUnsafeBufferPointer { all in
                var i = 0
                while i + 512 <= all.count {
                    for b in det.process(UnsafeBufferPointer(rebasing: all[i..<(i + 512)])) {
                        if let near = map.min(by: { abs($0 + cal.offset - b.time) < abs($1 + cal.offset - b.time) }) {
                            cal.observe(onset: b.time, strength: b.strength, nearestBeat: near, period: s.beat)
                        }
                        if settledAt == nil, cal.settled { settledAt = b.time }
                        if b.time <= firstKick + 8 * s.bar { errorAtBar8 = abs(cal.offset - skew) }
                    }
                    _ = det.drainBeats()
                    i += 512
                }
            }
            let bars = ((settledAt ?? .infinity) - firstKick) / s.bar
            print(String(format: "skew %+.0f ms: settled after %.1f bars of kicks, %.1f ms off at bar 8, %.1f ms off at the end",
                         skew * 1000, bars, errorAtBar8 * 1000, abs(cal.offset - skew) * 1000))
            XCTAssertLessThanOrEqual(bars, 8)
            XCTAssertLessThan(errorAtBar8, 0.008)
            XCTAssertEqual(cal.offset, skew, accuracy: 0.008)
        }
    }

    /// A trap pattern on a new song whose map sits -45 ms off its kicks, 73 ms from the carried-over guess: kick on 1
    /// and 3, clap on 2 and 4, syncopated 808s on the "a" of 2 and the "and" of 3. Only the on-beat hits count, and
    /// the song settles within 8 bars.
    func testNewSongIgnoresSyncopated808s() {
        let cal = GridCalibrator(offset: 0.028)
        cal.newTrack()
        let period = 60.0 / 140, skew = -0.045
        var rng = SystemRandomNumberGenerator()
        var settledBeat: Int?
        for k in 0..<64 {
            let beat = Double(k) * period
            let j = { Double.random(in: -0.004...0.004, using: &rng) }
            cal.observe(onset: beat + skew + j(), strength: 0.9, nearestBeat: beat, period: period)
            if k % 4 == 1 {   // the 808 on the "a" of 2: nearest map beat is beat 3
                cal.observe(onset: beat + 0.75 * period + skew + j(), strength: 0.9, nearestBeat: beat + period, period: period)
            }
            if k % 4 == 2 { cal.observe(onset: beat + 0.5 * period + skew + j(), strength: 0.9, nearestBeat: beat, period: period) }
            if settledBeat == nil, cal.settled { settledBeat = k }
        }
        XCTAssertLessThanOrEqual(settledBeat ?? .max, 32)
        XCTAssertEqual(cal.offset, skew, accuracy: 0.005)
    }

    func testIgnoresOffBeatsAndWeakOnsets() {
        let cal = GridCalibrator()
        for k in 0..<40 {
            let beat = Double(k) * 0.5
            cal.observe(onset: beat + 0.012, strength: 0.9, nearestBeat: beat, period: 0.5)     // kicks, 12 ms late
            cal.observe(onset: beat + 0.262, strength: 0.55, nearestBeat: beat, period: 0.5)    // off-beat hats, on the
            // same map offset: they count, as 8ths
            cal.observe(onset: beat + 0.137, strength: 0.6, nearestBeat: beat, period: 0.5)     // an 808 on a 16th
            cal.observe(onset: beat + 0.09, strength: 0.3, nearestBeat: beat, period: 0.5)      // weak junk
        }
        XCTAssertEqual(cal.offset, 0.012, accuracy: 0.002)
    }

    /// The file imac-stream writes (this is the one it wrote against a stand-in receiver, 2026-10-25).
    func testStreamSyncReadsTheStreamsHold() {
        let json = #"{"cushionMs":60,"at":1792946341.38,"delayMs":51.397,"pictureMs":18.603,"soundMs":70}"#
        XCTAssertEqual(StreamSync.hold(from: Data(json.utf8), now: 1792946342) ?? 0, 0.051397, accuracy: 1e-6)
        XCTAssertNil(StreamSync.hold(from: Data(json.utf8), now: 1792946350), "stale: the stream stopped")
        XCTAssertNil(StreamSync.hold(from: nil))
        XCTAssertNil(StreamSync.hold(from: Data("{}".utf8)))
        let big = #"{"at":100,"delayMs":900}"#
        XCTAssertEqual(StreamSync.hold(from: Data(big.utf8), now: 101), 0.4, "clamped")
    }

    /// Four rap songs played on 2026-10-25, as the tap heard them through the Beats. Each settles on its drums
    /// (where the hits pile up in 20 s stretches of drums, folded onto the 16ths: 0, +19, +7 and +18 ms), from
    /// zero and from the -223 ms "Plot Twist" once settled on, half a beat wrong, and carried into the next songs.
    func testRealSongsSettleOnTheirDrums() throws {
        struct Song: Decodable { var name: String; var period: Double; var onsets: [[Double]] }
        struct File: Decodable { var songs: [Song] }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "onsets-2026-10-25", withExtension: "json", subdirectory: "Fixtures"))
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        let want = ["KRYPTONITE": 0.0, "FWU": 0.019, "Who You Foolin": 0.007, "Plot Twist": 0.018]
        XCTAssertEqual(Set(file.songs.map(\.name)), Set(want.keys))
        for song in file.songs {
            for start in [0.0, -0.223] {
                let cal = GridCalibrator(offset: start)
                cal.newTrack()
                var settledAt: Double?
                for o in song.onsets {
                    // the fixture's beat is the nearest one under the old correction; only its place in the 8th matters
                    cal.observe(onset: o[0], strength: Float(o[1]), nearestBeat: o[0] - o[2], period: song.period)
                    if settledAt == nil, cal.settled { settledAt = o[0] }
                }
                print(String(format: "%@ from %+.0f ms: settled at %.0f s on %+.1f ms", song.name, start * 1000,
                             settledAt ?? -1, cal.offset * 1000))
                XCTAssertNotNil(settledAt, song.name)
                XCTAssertEqual(cal.offset, want[song.name] ?? 99, accuracy: 0.01, "\(song.name) from \(start)")
            }
        }
    }

    /// A trap beat whose clap and 808 on the "and" outweigh the kick on the beat: still the beat's own offset,
    /// not the off-beat's half a beat away.
    func testOffBeatHeavyTrapStaysOnTheBeat() {
        let cal = GridCalibrator()
        cal.newTrack()
        let period = 60.0 / 123, skew = 0.018
        var rng = SystemRandomNumberGenerator()
        for k in 0..<96 {
            let beat = Double(k) * period
            let j = { Double.random(in: -0.005...0.005, using: &rng) }
            cal.observe(onset: beat + skew + j(), strength: 0.6, nearestBeat: beat, period: period)
            cal.observe(onset: beat + 0.5 * period + skew + j(), strength: 1.0, nearestBeat: beat, period: period)
        }
        XCTAssertTrue(cal.settled)
        XCTAssertEqual(cal.offset, skew, accuracy: 0.005)
    }

    /// A saved guess from a bad song is pulled back near zero, and one song can't drag the next song's guess far.
    func testStartingGuessStaysNearZero() {
        let cal = GridCalibrator(offset: -0.223)
        XCTAssertEqual(cal.offset, -GridCalibrator.guessRange)
        cal.newTrack(seed: 0.3)
        XCTAssertEqual(cal.offset, GridCalibrator.guessRange)
        let c = GridCalibrator()
        c.newTrack()
        for k in 0..<40 { c.observe(onset: Double(k) * 0.5 + 0.09, strength: 0.9, nearestBeat: Double(k) * 0.5, period: 0.5) }
        XCTAssertEqual(c.offset, 0.09, accuracy: 0.002)
        XCTAssertEqual(c.baseline, 0.0225, accuracy: 0.001)
        c.newTrack()
        XCTAssertEqual(c.offset, c.baseline)
    }
}
