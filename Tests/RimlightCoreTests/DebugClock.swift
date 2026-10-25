import XCTest
@testable import RimlightCore

final class DebugClock: XCTestCase {
    func testTraceLock() throws {
        guard ProcessInfo.processInfo.environment["RIM_DEBUG"] != nil else { throw XCTSkip("set RIM_DEBUG") }
        let s = TimingTests.song
        let det = BeatDetector(sampleRate: s.sampleRate)
        let clock = BeatClock()
        s.samples.withUnsafeBufferPointer { all in
            var i = 0
            while i + 512 <= all.count, Double(i) / s.sampleRate < 21 {
                for b in det.process(UnsafeBufferPointer(rebasing: all[i..<(i + 512)])) {
                    clock.onset(at: b.time, strength: b.strength)
                    if b.time > 14 {
                        print(String(format: "onset %.2f beats (bar 8 = 0) s %.2f | period %@ anchor %@ locked %d tempo %@",
                                     (b.time - s.bars[8]) / s.beat, b.strength,
                                     clock.period.map { String(format: "%.4f", $0) } ?? "-",
                                     clock.anchor.map { String(format: "%.2f", ($0 - s.bars[8]) / s.beat) } ?? "-",
                                     clock.locked ? 1 : 0, det.tempo.map { String(format: "%.1f", $0) } ?? "-"))
                    }
                }
                _ = det.drainBeats()
                clock.setTempo(det.tempo)
                i += 512
            }
        }
    }
}
