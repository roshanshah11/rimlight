import XCTest
@testable import RimlightCore

final class StyleTests: XCTestCase {
    static let club = TimingTests.song
    static let trap = SyntheticTrap()
    static let ballad = SyntheticBallad()
    /// The trap's hook, as HookFinder would find it in its lyrics.
    static var trapHook: [Range<Double>] { [trap.hookTime..<(trap.hookTime + 8 * trap.bar)] }

    // the simulations are slow in debug builds: each one runs once and the tests share it
    nonisolated(unsafe) private static var cache: [String: ShowSimulator.Result] = [:]
    private static func run(_ key: String, _ make: () -> ShowSimulator.Result) -> ShowSimulator.Result {
        if let r = cache[key] { return r }
        let r = make()
        cache[key] = r
        return r
    }
    static var trapPlanned: ShowSimulator.Result {
        run("trap planned") { ShowSimulator.run(trap, mode: .planned, hooks: trapHook, startStyle: .hiphop, latency: 0.05) }
    }

    /// Each genre gets its style, from the audio alone and with Spotify's analysis, starting from rap (the app's
    /// default); a club track after a ballad still becomes club, and a ballad after a club track ambiance.
    func testJudgePicksEachGenre() {
        let cases: [(String, any TestTrack, ShowStyle)] = [("club", Self.club, .club), ("trap", Self.trap, .hiphop),
                                                           ("ballad", Self.ballad, .ambient)]
        for (name, song, want) in cases {
            for mode in [ShowSimulator.Mode.predictive, .planned] {
                let r = name == "trap" && mode == .planned ? Self.trapPlanned
                    : Self.run("\(name) \(mode)") { ShowSimulator.run(song, mode: mode, startStyle: .hiphop) }
                if want == .ambient {   // a ballad the live clock can't lock onto shows ambiance either way
                    XCTAssertTrue(r.frames.last?.ambiance ?? false, "\(name), \(mode)")
                } else {
                    XCTAssertEqual(r.frames.last?.style, want, "\(name), \(mode)")
                    // no ambiance while the beat plays (an outro without drums may fade to it). Live, the beat clock
                    // can't lock onto the trap's syncopated 808s, so it holds ambiance instead of flashing at random
                    // onsets: rap is lit from Spotify's beat map
                    if !(name == "trap" && mode == .predictive) {
                        let body = r.frames.filter { $0.t > song.duration * 0.25 && $0.t < song.duration * 0.75 }
                        XCTAssertFalse(body.contains { $0.ambiance }, "\(name), \(mode): ambiance in the middle of the song")
                    }
                }
            }
        }
        XCTAssertEqual(ShowSimulator.run(Self.club, mode: .planned, startStyle: .ambient).frames.last?.style, .club)
        XCTAssertEqual(ShowSimulator.run(Self.ballad, mode: .planned, startStyle: .club).frames.last?.style, .ambient)
    }

    /// The rap show: the hook (from the lyrics) is the big look and the verses aren't; the hook comes in with one
    /// soft white hit; the beat cutting out under the voice dims the rim, and there's no blackout the song doesn't
    /// have.
    func testTrapHookVerseAndDropout() {
        let r = Self.trapPlanned, s = Self.trap
        func frames(_ bars: Range<Int>) -> [ShowSimulator.Frame] {
            r.frames.filter { $0.t >= Double(bars.lowerBound) * s.bar && $0.t < Double(bars.upperBound) * s.bar }
        }
        let hook = frames(20..<28), verse = frames(8..<18)
        XCTAssertGreaterThan(Double(hook.filter { $0.state.section == .drop }.count) / Double(hook.count), 0.95)
        XCTAssertGreaterThan(Double(verse.filter { $0.state.section == .groove }.count) / Double(verse.count), 0.95)
        let mean = { (f: [ShowSimulator.Frame]) in f.map(\.state.master).reduce(0, +) / Float(f.count) }
        XCTAssertGreaterThan(mean(hook), mean(verse) + 0.1)
        XCTAssertEqual(verse.map(\.state.chaseLevel).max() ?? 1, 0, accuracy: 0.001, "no chase in a verse")

        let whites = r.flashes
        XCTAssertEqual(whites.count, 1, "one white hit, as the hook comes in: \(whites)")
        if let w = whites.first { XCTAssertEqual(w, s.hookTime, accuracy: 0.03) }
        XCTAssertLessThanOrEqual(r.frames.map(\.state.flash).max() ?? 1, 0.72)

        let cut = r.frames.filter { s.dropout.contains($0.t) && $0.t > s.dropout.lowerBound + 0.3 }
        XCTAssertLessThan(mean(cut), mean(verse) * 0.75, "dimmed while the beat is out")
        XCTAssertLessThan(cut.map(\.state.dark).max() ?? 1, 0.2, "but not blacked out: the voice is still going")
    }

    /// The rap show's hits land on the 808s and claps as they're heard (the show runs 50 ms behind the tap, as on
    /// the iMac stream), within a frame.
    func testTrapHitsLandOnThe808s() {
        let r = Self.trapPlanned, s = Self.trap
        // the hits the light can show: never more than 3 a second (ShowDirector.minFlashGap), so a clap a fifth of
        // a second before an 808 takes the 808's turn
        var verse: [Double] = []
        for h in s.hits where h >= 6 * s.bar && h < 18 * s.bar {
            if let last = verse.last, h - last < ShowDirector.minFlashGap { continue }
            verse.append(h)
        }
        let lit = r.hits
        var errors: [Double] = []
        for h in verse { if let near = lit.min(by: { abs($0 - h) < abs($1 - h) }), abs(near - h) < 0.05 { errors.append(near - h) } }
        let share = Double(errors.count) / Double(verse.count)
        let mean = errors.reduce(0, +) / Double(max(1, errors.count))
        print(String(format: "trap: %d of %d verse hits lit (%.0f%%), mean %+.1f ms", errors.count, verse.count, share * 100, mean * 1000))
        XCTAssertGreaterThan(share, 0.85)
        XCTAssertEqual(mean, 0, accuracy: 0.017)
    }

    /// A slow song is ambiance once judged: no hits, no white, no blackout, and a wash that breathes smoothly.
    func testBalladIsAmbiance() {
        for mode in [ShowSimulator.Mode.predictive, .planned] {
            let r = Self.run("ballad \(mode)") { ShowSimulator.run(Self.ballad, mode: mode, startStyle: .hiphop) }
            guard let from = r.frames.firstIndex(where: { $0.ambiance }) else { return XCTFail("never ambient, \(mode)") }
            let after = r.frames[(from + 300)...]   // the look blends in over a few seconds
            XCTAssertLessThan(after.map(\.state.pulse).max() ?? 1, 0.05, "\(mode)")
            XCTAssertEqual(after.map(\.state.flash).max() ?? 1, 0, accuracy: 0.01, "\(mode)")
            XCTAssertEqual(after.map(\.state.dark).max() ?? 1, 0, accuracy: 0.01, "\(mode)")
            let masters = after.map(\.state.master)
            let steps = zip(masters.dropFirst(), masters).map { abs($0 - $1) }
            XCTAssertLessThan(steps.max() ?? 1, 0.02, "smooth, \(mode)")
            XCTAssertGreaterThan((masters.max() ?? 0) - (masters.min() ?? 0), 0.05, "it breathes, \(mode)")
        }
    }

    func testHookFinderFindsTheRepeatedBlock() {
        var lines: [LyricLine] = []
        var t = 8000.0
        func add(_ w: String) { lines.append(LyricLine(t: t, w: w)); t += 2500 }
        let hook = ["I been on the road all night (yeah)", "Got my day ones by my side", "Every city lit up bright",
                    "Nonstop, we don't stop tonight"]
        var hookStarts: [Double] = []
        let words = ["money", "city", "night", "phone", "ride", "gold", "rain", "block", "ring", "crowd", "late", "fast",
                     "smoke", "glass", "drive", "wave", "dream", "shine", "count", "pull", "deep", "real", "cold", "fire"]
        for v in 0..<3 {
            for k in 0..<8 {   // every verse line its own words
                let i = v * 8 + k
                add("\(words[i % 24]) \(words[(i * 7 + 3) % 24]) \(words[(i * 5 + 11) % 24]) number \(i)")
            }
            hookStarts.append(t)
            for (i, h) in hook.enumerated() { add(v == 2 && i == 1 ? "Got my real ones by my side" : h) }   // a word changed
        }
        add("♪")
        let found = HookFinder.hooks(lines)
        XCTAssertEqual(found.count, 3)
        for (f, s) in zip(found, hookStarts) {
            XCTAssertEqual(f.lowerBound, s / 1000, accuracy: 0.001)
            XCTAssertEqual(f.upperBound, s / 1000 + 4 * 2.5, accuracy: 0.001)
        }
    }

    func testHookFinderChantAndNothing() {
        // a one-line chant that comes back four times is a hook; a line said twice isn't
        var lines: [LyricLine] = []
        var t = 0.0
        for k in 0..<20 {
            lines.append(LyricLine(t: t, w: k % 5 == 4 ? "run it up run it up run it up" : "line \(k) says something new"))
            t += 2000
        }
        XCTAssertEqual(HookFinder.hooks(lines).count, 4)
        let plain = (0..<20).map { LyricLine(t: Double($0) * 2000, w: $0 == 3 || $0 == 11 ? "same words twice over" : "line \($0) is new") }
        XCTAssertTrue(HookFinder.hooks(plain).isEmpty)
    }

    /// Beats from Spotify's map keep coming while the tap hears nothing (it restarted, or the sound plays elsewhere):
    /// those beats aren't evidence, so a rap song isn't judged ambiance off silence.
    func testSilenceIsNotEvidence() {
        let d = ShowDirector(palette: Palette.fallback)
        d.setStyle(.hiphop)
        for k in 0..<80 {
            let t = Double(k) * 0.4
            d.beat(at: t, strength: 0.8, downbeat: k % 4 == 0)
            _ = d.frame(at: t + 0.01, MusicInput(energy: 0, level: 0, bass: 0, treble: 0, tempo: 150))
        }
        XCTAssertNil(d.judge.verdict)
        XCTAssertEqual(d.style, .hiphop)
    }
}

extension StyleTests {
    /// On the beat grid, a rap hit off the 16ths (a voice, a synth stab) isn't lit; one on a 16th is.
    func testOffGridHitsAreNotLit() {
        func pulses(onGrid: Bool) -> [Double] {
            let d = ShowDirector(palette: Palette.fallback)
            d.forcedStyle = .hiphop
            d.setStyle(.hiphop)
            d.onGrid = onGrid
            let period = 60.0 / 134
            var lit: [Double] = [], last: Float = 0
            var t = 0.0
            var k = 0
            while t < 40 {
                if Double(k) * period <= t {
                    d.beat(at: Double(k) * period, strength: 0.8, downbeat: k % 4 == 0)
                    if k % 4 == 2, k >= 8 { d.heard(onset: Double(k) * period, strength: 0.9) }   // a clap on 3: on the grid
                    k += 1
                }
                let bar = Int(t / (4 * period))
                if bar >= 2, Int((t - 0.005) / 0.6) != Int(t / 0.6) {   // every 0.6 s: off the 16ths of 134 BPM most of the time
                    d.heard(onset: t, strength: 0.9)
                }
                let f = d.frame(at: t, MusicInput(energy: 0.7, level: 0.7, bass: 0.7, treble: 0.4, tempo: 134, bassShare: 8, lowLevel: 0.8))
                if f.pulse > last + 0.15 { lit.append(t) }
                last = f.pulse
                t += 0.005
            }
            return lit
        }
        let off = pulses(onGrid: true), all = pulses(onGrid: false)
        let q = 60.0 / 134 / 4
        func offGrid(_ ts: [Double]) -> Int { ts.filter { t in let x = t.truncatingRemainder(dividingBy: q); return min(x, q - x) > 0.03 }.count }
        XCTAssertGreaterThan(offGrid(all), 3, "without the grid, off-grid hits are lit")
        XCTAssertEqual(offGrid(off), 0, "on the grid, none are")
        XCTAssertGreaterThanOrEqual(off.count, 10, "and the claps on the grid still are")
    }
}
