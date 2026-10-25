import XCTest
@testable import RimlightCore

final class ShowDirectorTests: XCTestCase {
    private let colors = [RGB(1, 0.2, 0.3), RGB(0.2, 0.4, 1), RGB(1, 0.8, 0.1), RGB(0.3, 1, 0.5)]

    /// Drive the director at 120 fps with beats at `bpm` and a loudness curve; returns every frame.
    private func run(_ d: ShowDirector, seconds: Double, bpm: Double, start: Double = 0,
                     energy: (Double) -> Float, bass: Float = 0.7) -> [(t: Double, s: LightState, beat: Int)] {
        var out: [(Double, LightState, Int)] = []
        let period = 60 / bpm
        var nextBeat = start + period
        var t = start
        while t < start + seconds {
            if t >= nextBeat { d.beat(at: nextBeat, strength: 0.8); nextBeat += period }
            out.append((t, d.frame(at: t, energy: energy(t), bass: bass, treble: 0.5, tempo: bpm), d.beatIndex))
            t += 1.0 / 120
        }
        return out
    }

    func testQuietThenBuildThenDrop() {
        let d = ShowDirector(palette: colors)
        d.forcedStyle = .club   // these feed bare loudness curves (no bass share): the club grammar on its own
        let frames = run(d, seconds: 48, bpm: 120) { t in
            t < 16 ? 0.2 : (t < 32 ? Float(0.35 + (t - 16) / 16 * 0.25) : 0.92)
        }
        let order = frames.map(\.s.section).reduce(into: [Section]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(order.first, .quiet)
        XCTAssertTrue(order.contains(.build), "\(order)")
        XCTAssertEqual(order.last, .drop, "\(order)")
        let dropStart = frames.firstIndex { $0.s.section == .drop }!
        XCTAssertGreaterThan(frames[dropStart].s.flash, 0.9)   // the drop lands with a white hit
        XCTAssertLessThan(frames[dropStart].t, 33.1, "the drop at 32 s landed late")
        // quiet looks stay calm: no flash, small pulses
        XCTAssertTrue(frames.filter { $0.s.section == .quiet }.allSatisfy { $0.s.flash < 0.01 && $0.s.pulse < 0.2 })
    }

    func testNeverMoreThanThreeJumpsASecond() {
        // 240 BPM at full energy would be four kicks a second
        let d = ShowDirector(palette: colors)
        d.forcedStyle = .club   // these feed bare loudness curves (no bass share): the club grammar on its own
        let frames = run(d, seconds: 20, bpm: 240) { _ in 0.95 }
        var jumps: [Double] = []
        var prev: Float = 0
        for f in frames {
            let level = f.s.pulse + f.s.flash
            if level - prev > 0.1 { jumps.append(f.t) }
            prev = level
        }
        XCTAssertFalse(jumps.isEmpty)
        for (i, t) in jumps.enumerated() {
            XCTAssertLessThanOrEqual(jumps[i...].prefix { $0 < t + 1 }.count, 3, "too many flashes after \(t) s")
        }
    }

    func testLooksAndColorsChangeOnlyOnBarLines() {
        let d = ShowDirector(palette: colors)
        d.forcedStyle = .club   // these feed bare loudness curves (no bass share): the club grammar on its own
        let frames = run(d, seconds: 60, bpm: 128) { t in t < 20 ? 0.2 : (t < 40 ? 0.55 : 0.92) }
        for i in 1..<frames.count {
            let (a, b) = (frames[i - 1], frames[i])
            // drops land on the beat they're heard; builds and breakdowns start when they're clear
            let landing = b.s.section == .drop && a.s.section != .drop
            let free = landing || b.s.section == .build || b.s.section == .quiet || (a.s.section == .quiet && b.s.section == .groove)
            if a.s.section != b.s.section, !free { XCTAssertEqual(d.beatInBar(b.beat), 0, "section changed mid-bar at \(b.t)") }
            if a.s.colorA != b.s.colorA, !landing { XCTAssertEqual(d.beatInBar(b.beat), 0, "color changed mid-bar at \(b.t)") }
        }
        // groove holds a color pair for 8 bars before rotating
        let groove = frames.filter { $0.s.section == .groove }
        let changes = zip(groove, groove.dropFirst()).filter { $0.0.s.colorA != $0.1.s.colorA }.map(\.1.beat)
        for (x, y) in zip(changes, changes.dropFirst()) { XCTAssertGreaterThanOrEqual(y - x, 32) }
    }

    func testSlowJamsSwapColorsOncePerBar() {
        // 80 BPM, steady mid loudness: a groove that changes color every bar, not every beat
        let d = ShowDirector(palette: colors)
        d.forcedStyle = .club   // these feed bare loudness curves (no bass share): the club grammar on its own
        let frames = run(d, seconds: 40, bpm: 80) { t in t < 6 ? 0.2 : 0.6 }
        XCTAssertEqual(d.mood, .low)
        let groove = frames.filter { $0.s.section == .groove && $0.t > 15 }
        let swaps = zip(groove, groove.dropFirst()).filter { $0.0.s.alternate != $0.1.s.alternate }.count
        let bars = (groove.last!.t - groove.first!.t) / 3.0        // a bar at 80 BPM is 3 s
        XCTAssertLessThanOrEqual(Double(swaps), bars + 1, "\(swaps) swaps in \(bars) bars")
    }

    func testFastLoudSongsSwapOnTheBeat() {
        let d = ShowDirector(palette: colors)
        d.forcedStyle = .club   // these feed bare loudness curves (no bass share): the club grammar on its own
        let frames = run(d, seconds: 40, bpm: 128) { t in t < 6 ? 0.2 : 0.8 }
        XCTAssertEqual(d.mood, .high)
        let groove = frames.filter { $0.s.section == .groove && $0.t > 15 }
        let swaps = zip(groove, groove.dropFirst()).filter { $0.0.s.alternate != $0.1.s.alternate }.count
        let beats = (groove.last!.t - groove.first!.t) / (60 / 128)
        XCTAssertGreaterThan(Double(swaps), beats * 0.8)
    }

    func testFlashesCanBeTurnedOff() {
        let d = ShowDirector(palette: colors)
        d.forcedStyle = .club   // these feed bare loudness curves (no bass share): the club grammar on its own
        d.allowFlashes = false
        let frames = run(d, seconds: 30, bpm: 128) { t in t < 12 ? 0.2 : 0.95 }
        XCTAssertTrue(frames.allSatisfy { $0.s.flash == 0 })
    }
}
