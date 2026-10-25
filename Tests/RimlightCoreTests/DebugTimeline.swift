import XCTest
@testable import RimlightCore

final class DebugTimeline: XCTestCase {
    func testPrintTimeline() throws {
        guard ProcessInfo.processInfo.environment["RIM_DEBUG"] != nil else { throw XCTSkip("set RIM_DEBUG") }
        let s = TimingTests.song
        let det = BeatDetector(sampleRate: s.sampleRate)
        var bars: [(e: Float, lmin: Float, lmax: Float, lo: Float, hi: Float, tilt: Float)] = Array(repeating: (0, 1, 0, 0, 0, 0), count: SyntheticSong.barCount)
        var onsets: [Double] = []
        s.samples.withUnsafeBufferPointer { all in
            var i = 0
            while i + 512 <= all.count {
                for b in det.process(UnsafeBufferPointer(rebasing: all[i..<(i + 512)])) { onsets.append(b.time) }
                _ = det.drainBeats()
                i += 512
                let b = min(SyntheticSong.barCount - 1, Int(Double(i) / s.sampleRate / s.bar))
                bars[b].e = det.features.loudness
                bars[b].lo = det.features.lowLoud
                bars[b].hi = det.features.highLoud
                bars[b].tilt = det.features.tilt
                bars[b].lmin = min(bars[b].lmin, det.features.level)
                bars[b].lmax = max(bars[b].lmax, det.features.level)
            }
        }
        let r = ShowSimulator.run(s, mode: .predictive)
        for b in 0..<SyntheticSong.barCount {
            let fr = r.frames.filter { $0.t >= s.bars[b] && $0.t < s.bars[b] + s.bar }
            let secs = Set(fr.map { $0.state.section.rawValue }).sorted().joined(separator: ",")
            let dark = fr.map(\.state.dark).max() ?? 0
            let on = onsets.filter { $0 >= s.bars[b] && $0 < s.bars[b] + s.bar }.map { String(format: "%.2f", ($0 - s.bars[b]) / s.beat) }
            print(String(format: "bar %2d %-7@ tilt %5.1f loud %.2f low %.2f high %.2f level %.2f-%.2f dark %.2f look %@", b,
                         s.section(atBar: b).rawValue, bars[b].tilt, bars[b].e, bars[b].lo, bars[b].hi, bars[b].lmin, bars[b].lmax, dark, secs))
        }
        var lines: [String] = []
        _ = ShowSimulator.run(s, mode: .predictive, until: s.dropTime + 0.6) { t, st, _ in
            if t > s.dropTime - 1.2 { lines.append(String(format: "t %.3f %@ dark %.2f pulse %.2f flash %.2f", t - s.dropTime, st.section.rawValue, st.dark, st.pulse, st.flash)) }
        }
        print(lines.enumerated().filter { $0.offset % 4 == 0 }.map(\.element).joined(separator: "\n"))
        let pr = ShowSimulator.run(s, mode: .predictive)
        let hits = pr.hits.filter { $0 >= s.bars[9] && $0 < s.bars[16] }
        print("groove hits (beats from bar 9):", hits.map { String(format: "%.2f", ($0 - s.bars[9]) / s.beat) }.joined(separator: " "))
        let rr = ShowSimulator.run(s, mode: .reactive)
        print("reactive hits in bar 10:", rr.hits.filter { $0 >= s.bars[10] && $0 < s.bars[11] }.map { String(format: "%.3f", $0 - s.bars[10]) })
        print("kicks in bar 10:", s.kickBeats.filter { $0 >= s.bars[10] && $0 < s.bars[11] }.map { String(format: "%.3f", $0 - s.bars[10]) })
    }
}
