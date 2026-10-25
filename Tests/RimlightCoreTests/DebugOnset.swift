import XCTest
@testable import RimlightCore

final class DebugOnset: XCTestCase {
    func testOnsetBias() throws {
        guard ProcessInfo.processInfo.environment["RIM_DEBUG"] != nil else { throw XCTSkip("set RIM_DEBUG") }
        let s = TimingTests.song
        let det = BeatDetector(sampleRate: s.sampleRate)
        var onsets: [Double] = []
        s.samples.withUnsafeBufferPointer { all in
            var i = 0
            while i + 512 <= all.count {
                onsets += det.process(UnsafeBufferPointer(rebasing: all[i..<(i + 512)])).map(\.time)
                _ = det.drainBeats()
                i += 512
            }
        }
        let kicks = s.kickBeats.filter { $0 > s.bars[9] }
        let errs = kicks.compactMap { k in onsets.map { $0 - k }.min(by: { abs($0) < abs($1) }) }.filter { abs($0) < 0.05 }
        let mean = errs.reduce(0, +) / Double(errs.count)
        let std = (errs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(errs.count)).squareRoot()
        print(String(format: "onset vs kick: mean %+.2f ms, std %.2f ms, n %d", mean * 1000, std * 1000, errs.count))
        // other kick shapes: a click-heavy 909-style kick and a soft 808
        for (name, f0, decay, click) in [("909", 180.0, 14.0, 0.5), ("808", 60.0, 4.0, 0.0), ("acoustic", 90.0, 20.0, 0.3)] {
            let sr = 48000.0
            var x = [Float](repeating: 0, count: Int(sr * 10))
            var truth: [Double] = []
            var seed: UInt64 = 7
            for k in 0..<20 {
                let t0 = 0.3 + Double(k) * 0.47
                truth.append(t0)
                for i in 0..<Int(0.3 * sr) {
                    let tt = Double(i) / sr
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let n = Float(Int64(bitPattern: seed) >> 11) / Float(1 << 52)
                    let v = Float(sin(2 * .pi * (f0 * 0.4 * tt + f0 * 0.6 * (1 - exp(-tt * 30)) / 30)) * exp(-tt * decay))
                        + Float(click) * n * Float(exp(-tt * 300))
                    x[Int(t0 * sr) + i] += 0.6 * v
                }
            }
            let d = BeatDetector(sampleRate: sr)
            var on: [Double] = []
            x.withUnsafeBufferPointer { all in
                var i = 0
                while i + 512 <= all.count { on += d.process(UnsafeBufferPointer(rebasing: all[i..<(i + 512)])).map(\.time); _ = d.drainBeats(); i += 512 }
            }
            let e = truth.dropFirst(3).compactMap { k in on.map { $0 - k }.min(by: { abs($0) < abs($1) }) }.filter { abs($0) < 0.05 }
            let m = e.reduce(0, +) / Double(max(1, e.count))
            print(String(format: "%@ kick: mean %+.2f ms, n %d", name, m * 1000, e.count))
        }
    }
}
