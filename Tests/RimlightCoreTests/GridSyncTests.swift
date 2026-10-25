import XCTest
@testable import RimlightCore

/// The Spotify path end to end on simulated clocks: Spotify's reported position runs 60 ms ahead of the audio it
/// actually plays; kicks are heard exactly on the true beats. The map's beats must come out on the true beats.
final class GridSyncTests: XCTestCase {
    func testMapBeatsConvergeOnTheRealSound() {
        let bpm = 100.0, period = 60 / bpm
        let trueBeats = (0..<400).map { 1.0 + Double($0) * period }        // track seconds
        let grid = BeatGrid(uri: "u", tempo: bpm, beats: trueBeats, confidence: Array(repeating: 0.8, count: 400),
                            bars: stride(from: 0, to: 400, by: 4).map { trueBeats[$0] })
        let sync = GridSync()
        sync.setGrid(grid)

        // host time h; the track started at host 1000 (track 0 sounds at h = 1000); epoch = host*1000 + 5e6 ms
        let start = 1000.0, skew = 0.060
        func now(_ h: Double) -> GridSync.Now { .init(host: h, epochMs: h * 1000 + 5_000_000) }
        // Spotify reports a position 60 ms ahead of the sound, every 5 s, with a little jitter
        var clock = PlaybackClock()
        var errs: [Double] = []
        var h = start
        var nextReport = start
        var nextKick = 0
        var seed: UInt64 = 1
        while h < start + 120 {
            if h >= nextReport {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let jitter = Double(Int64(bitPattern: seed) % 20) / 1000          // +/-20 ms
                clock.update(progressMs: ((h - start) + skew + jitter) * 1000, reportedAt: now(h).epochMs, paused: false)
                nextReport += 5
            }
            // kicks the tap hears: on the true beats (sound time = start + beat)
            while nextKick < trueBeats.count, start + trueBeats[nextKick] <= h {
                sync.observe(onset: start + trueBeats[nextKick], strength: 0.9, clock: clock, now: now(h))
                nextKick += 1
            }
            for b in sync.beats(through: h, clock: clock, now: now(h)) where h > start + 30 {
                errs.append(b.sound - (start + b.track))       // where it says the beat sounds vs where it does
                // and the corrected track time matches the true beat it names
                XCTAssertTrue(trueBeats.contains { abs($0 - b.track) < 1e-9 })
            }
            h += 1.0 / 60
        }
        XCTAssertTrue(sync.calibrator.confident)
        // the map says each beat sounds 60 ms early, so the correction is +60 ms (within the reports' jitter)
        XCTAssertEqual(sync.calibrator.offset, skew, accuracy: 0.012, "offset \(sync.calibrator.offset)")
        let worst = errs.map(abs).max() ?? 1
        print(String(format: "GridSync: offset %.1f ms (Spotify %+.0f ms off the sound), beats within %.1f ms after 30 s",
                     sync.calibrator.offset * 1000, skew * 1000, worst * 1000))
        XCTAssertLessThan(worst, 0.012)
    }
}
