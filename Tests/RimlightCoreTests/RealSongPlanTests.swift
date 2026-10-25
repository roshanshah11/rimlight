import XCTest
@testable import RimlightCore

/// SongPlan on real Spotify analyses (derived fixtures): drops are moments with a setup, never the whole song.
final class RealSongPlanTests: XCTestCase {
    func analysis(_ name: String) throws -> SongAnalysis {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        let d = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let sections = (d["sections"] as? [[Double]] ?? []).map { SongAnalysis.SongSection(start: $0[0], duration: $0[1], loudness: $0[2]) }
        return SongAnalysis(tempo: d["tempo"] as? Double ?? 0, beats: d["beats"] as? [Double] ?? [], bars: d["bars"] as? [Double] ?? [],
                            sections: sections, beatLoudness: d["loudness"] as? [Double] ?? [])
    }

    func check(_ name: String, drops expected: ClosedRange<Int>) throws {
        let plan = try XCTUnwrap(SongPlan.make(try analysis(name)))
        XCTAssertTrue(expected.contains(plan.drops.count), "\(name): \(plan.drops.count) drops")
        // no drop run longer than 8 bars; every drop has a build right before it and a blackout into it
        var run = 0
        for c in plan.cues { run = c == .drop ? run + 1 : 0; XCTAssertLessThanOrEqual(run, 8, name) }
        for d in plan.drops {
            let i = try XCTUnwrap(plan.barIndex(at: d))
            if case .build = plan.cues[max(0, i - 1)] {} else { XCTFail("\(name): no build before the drop at \(d)") }
            XCTAssertTrue(plan.inBlackout(d - 0.05), "\(name): no blackout into the drop at \(d)")
        }
        // most of the song is not a drop
        XCTAssertLessThan(Double(plan.cues.filter { $0 == .drop }.count) / Double(plan.cues.count), 0.35, name)
    }

    func testWoods() throws { try check("woods", drops: 2...3) }            // flat-mastered: once read as one long drop
    func testNovember() throws { try check("november", drops: 2...4) }
    func testAlottaCake() throws { try check("alotta-cake", drops: 2...4) }
}
