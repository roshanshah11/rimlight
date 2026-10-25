import XCTest
@testable import RimlightCore

/// Timing against the truth: a synthetic track with known beats, build, gap and drop.
final class TimingTests: XCTestCase {
    static let song = SyntheticSong()

    struct Report: CustomStringConvertible {
        var mean = 0.0, std = 0.0, worst = 0.0, matched = 0, expected = 0, extra = 0
        var description: String {
            String(format: "mean %+.1f ms, std %.1f ms, worst %+.1f ms, %d/%d kicks lit, %d extra hits",
                   mean * 1000, std * 1000, worst * 1000, matched, expected, extra)
        }
    }

    /// Error of each visible hit against the kick it belongs to, over groove and drop bars.
    func report(_ r: ShowSimulator.Result, from: Double, to: Double) -> Report {
        let song = Self.song
        let kicks = song.kickBeats.filter { $0 >= from && $0 < to }
        let hits = r.hits.filter { $0 >= from - 0.1 && $0 < to }
        var errs: [Double] = []
        var used = Set<Int>()
        for k in kicks {
            if let (i, h) = hits.enumerated().filter({ !used.contains($0.offset) }).min(by: { abs($0.element - k) < abs($1.element - k) }),
               abs(h - k) < 0.12 {
                used.insert(i)
                errs.append(h - k)
            }
        }
        var rep = Report()
        rep.expected = kicks.count
        rep.matched = errs.count
        rep.extra = hits.count - used.count
        guard !errs.isEmpty else { return rep }
        rep.mean = errs.reduce(0, +) / Double(errs.count)
        rep.std = (errs.map { ($0 - rep.mean) * ($0 - rep.mean) }.reduce(0, +) / Double(errs.count)).squareRoot()
        rep.worst = errs.max(by: { abs($0) < abs($1) }) ?? 0
        return rep
    }

    func testReactiveLightingIsLate() {
        // the old way, for comparison: light when the detector reports the kick
        let s = Self.song
        let r = ShowSimulator.run(s, mode: .reactive)
        let rep = report(r, from: s.bars[10], to: s.bars[16])
        print("reactive, groove:", rep)
        // lighting on the report is either late or locked to the off-beat
        XCTAssertTrue(rep.matched < rep.expected / 2 || rep.mean > 0.025, "\(rep)")
    }

    func testPredictiveBeatsLandOnTheKick() {
        let s = Self.song
        let r = ShowSimulator.run(s, mode: .predictive)
        let groove = report(r, from: s.bars[10], to: s.bars[16])
        let drop = report(r, from: s.dropTime + s.bar, to: s.bars[32])
        print("predictive, groove:", groove)
        print("predictive, drop:  ", drop)
        for rep in [groove, drop] {
            XCTAssertLessThanOrEqual(abs(rep.mean), 0.010)
            XCTAssertLessThanOrEqual(rep.std, 0.010)
            XCTAssertGreaterThanOrEqual(rep.matched, rep.expected - 1)
        }
    }

    func testLiveDropLandsOnTheDownbeatAfterTheGap() {
        let s = Self.song
        let r = ShowSimulator.run(s, mode: .predictive)
        let hit = r.flashes.first { $0 > s.gap.lowerBound - 0.5 }
        print("live: drop at \(s.dropTime) s, white hit at \(hit.map { String(format: "%.3f", $0) } ?? "none")")
        XCTAssertNotNil(hit)
        XCTAssertLessThan(abs((hit ?? 0) - s.dropTime), 0.040)
        // dark within ~0.1 s of the music stopping, through to the drop
        let gapFrames = r.frames.filter { $0.t > s.gap.lowerBound + 0.12 && $0.t < s.dropTime - 0.01 }
        XCTAssertFalse(gapFrames.isEmpty)
        XCTAssertTrue(gapFrames.allSatisfy { $0.state.dark > 0.8 }, "not dark in the gap")
    }

    func testPlannedShowHitsTheDropExactly() {
        let s = Self.song
        let plan = SongPlan.make(s.analysis)!
        XCTAssertEqual(plan.drops.count, 1)
        XCTAssertEqual(plan.drops.first ?? 0, s.dropTime, accuracy: 0.001)
        let r = ShowSimulator.run(s, mode: .planned)
        let hit = r.flashes.first { $0 > s.dropTime - 1 }
        print("planned: drop at \(s.dropTime) s, white hit at \(hit.map { String(format: "%.4f", $0) } ?? "none")")
        XCTAssertLessThan(abs((hit ?? 0) - s.dropTime), 1.0 / 60 + 0.0005)   // within one frame
        // dark for the whole silent gap (planned from the analysis, so it starts on time), lit just before it
        XCTAssertEqual(plan.blackouts.first?.lowerBound ?? 0, s.gap.lowerBound, accuracy: 0.001)
        let inGap = r.frames.filter { $0.t > s.gap.lowerBound + 0.03 && $0.t < s.dropTime - 0.005 }
        let before = r.frames.filter { $0.t > s.gap.lowerBound - s.beat * 0.6 && $0.t < s.gap.lowerBound - 0.02 }
        XCTAssertTrue(inGap.allSatisfy { $0.state.dark > 0.8 }, "lit during the gap")
        XCTAssertTrue(before.allSatisfy { $0.state.dark < 0.2 }, "dark before the gap")
        // the build is on screen before the drop, starting on a bar line
        XCTAssertEqual(r.section(at: s.dropTime - s.bar * 2), .build)
        XCTAssertEqual(r.section(at: s.dropTime + s.bar), .drop)
        XCTAssertEqual(r.section(at: s.bars[4]), .quiet)
    }

    func testPlannedSectionsMatchTheSong() {
        let s = Self.song
        let r = ShowSimulator.run(s, mode: .planned)
        var right = 0
        for b in 0..<SyntheticSong.barCount {
            if r.section(at: s.bars[b] + s.bar / 2) == s.section(atBar: b) { right += 1 }
        }
        print("planned sections: \(right)/\(SyntheticSong.barCount) bars right")
        XCTAssertGreaterThanOrEqual(right, SyntheticSong.barCount - 4)
    }

    func testNoMoreThanThreeJumpsASecondAnywhere() {
        for mode in [ShowSimulator.Mode.predictive, .planned] {
            let r = ShowSimulator.run(Self.song, mode: mode)
            let hits = r.hits
            for (i, t) in hits.enumerated() {
                XCTAssertLessThanOrEqual(hits[i...].prefix { $0 < t + 1 }.count, 3, "\(mode): too many at \(t)")
            }
        }
    }
}
