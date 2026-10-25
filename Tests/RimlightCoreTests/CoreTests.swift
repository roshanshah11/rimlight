import XCTest
@testable import RimlightCore

final class TimelineTests: XCTestCase {
    func testClockExtrapolatesOnlyWhilePlaying() {
        var c = PlaybackClock(progressMs: 10_000, reportedAt: 1_000, paused: false, durationMs: 200_000)
        XCTAssertEqual(c.position(at: 3_500), 12_500)
        c.paused = true
        XCTAssertEqual(c.position(at: 9_000), 10_000)
        let end = PlaybackClock(progressMs: 199_000, reportedAt: 0, paused: false, durationMs: 200_000)
        XCTAssertEqual(end.position(at: 5_000), 200_000)
    }

    func testGridPulseAndDownbeats() {
        let g = BeatGrid(uri: "u", tempo: 120, beats: [1.5, 0.5, 1.0, 2.0], confidence: [0.9, 0.9, 0.9, 0.9], bars: [0.5, 2.0])
        XCTAssertEqual(g.beats, [0.5, 1.0, 1.5, 2.0])
        XCTAssertEqual(g.downbeat, [true, false, false, true])
        XCTAssertNil(g.lastBeat(atOrBefore: 0.4))
        XCTAssertEqual(g.lastBeat(atOrBefore: 1.2), 1)
        XCTAssertEqual(g.pulse(at: 0.5, tau: 0.15), 1, accuracy: 1e-6)          // downbeat, full
        XCTAssertEqual(g.pulse(at: 1.0, tau: 0.15), 0.75, accuracy: 1e-6)       // ordinary beat
        XCTAssertEqual(g.pulse(at: 1.3, tau: 0.15), 0.75 * Float(exp(-2.0)), accuracy: 1e-4)
        XCTAssertEqual(g.pulse(at: 0.1, tau: 0.15), 0)
    }

    func testPulseTrainWaitsForAudibleTime() {
        var p = PulseTrain()
        p.add(at: 10.2, strength: 1)                 // detected now, audible 200 ms later (Bluetooth)
        XCTAssertEqual(p.value(at: 10.1, tau: 0.15), 0)
        XCTAssertEqual(p.value(at: 10.2, tau: 0.15), 1, accuracy: 1e-6)
        XCTAssertLessThan(p.value(at: 10.6, tau: 0.15), 0.1)
    }

    func testLyricsLookup() {
        let l = LyricsTimeline(uri: "u", lines: [LyricLine(t: 5000, w: "second"), LyricLine(t: 1000, w: "first"),
                                                LyricLine(t: 9000, w: "♪"), LyricLine(t: 12000, w: "")])
        XCTAssertNil(l.line(at: 500))
        XCTAssertEqual(l.line(at: 1000), "first")
        XCTAssertEqual(l.line(at: 7000), "second")
        XCTAssertNil(l.line(at: 9500))                // instrumental marker
        XCTAssertNil(l.line(at: 13000))               // empty line ends the previous one
        XCTAssertEqual(l.next(after: 1500), "second")
    }
}

final class PaletteTests: XCTestCase {
    private func image(_ colors: [(UInt8, UInt8, UInt8)], each: Int) -> [UInt8] {
        colors.flatMap { c in Array(repeating: [c.0, c.1, c.2, 255], count: each).flatMap { $0 } }
    }

    func testPicksTheVividColors() {
        let px = image([(200, 30, 40), (30, 60, 210), (20, 20, 20)], each: 600)
        let p = Palette.extract(rgba: px)
        XCTAssertEqual(p.count, 2, p.map(\.hex).joined(separator: " "))     // the black isn't a light color
        let hues = p.map { $0.hsv.h }
        XCTAssertTrue(hues.contains { $0 < 0.05 || $0 > 0.95 }, "red missing: \(p.map(\.hex))")
        XCTAssertTrue(hues.contains { abs($0 - 0.63) < 0.06 }, "blue missing: \(p.map(\.hex))")
    }

    func testDarkArtStillGlowsInItsOwnHue() {
        let p = Palette.extract(rgba: image([(40, 10, 60), (10, 10, 10)], each: 800))
        XCTAssertEqual(p.count, 2, p.map(\.hex).joined(separator: " "))       // the purple, then a white for it
        XCTAssertGreaterThan(p[0].hsv.v, 0.7, p[0].hex)
        XCTAssertGreaterThan(p[0].hsv.s, 0.6, "a light, not a pastel: \(p[0].hex)")
        XCTAssertEqual(p[0].hsv.h, RGB(40 / 255, 10 / 255, 60 / 255).hsv.h, accuracy: 0.05)   // still purple
        XCTAssertLessThan(p[1].hsv.s, 0.15)
    }

    func testSaturatedCoversGiveSaturatedLights() {
        // a pure red cover (like Nothing But the Beat) should light red, not salmon
        let p = Palette.extract(rgba: image([(220, 20, 40), (250, 250, 250)], each: 800))
        XCTAssertGreaterThan(p[0].hsv.s, 0.8, p[0].hex)
        XCTAssertTrue(p[0].hsv.h < 0.03 || p[0].hsv.h > 0.95, p[0].hex)
    }

    func testNearBlackCastsDontBecomeColors() {
        // dark red art on near-black with a faint blue cast (TRAPSOUL): red only, no invented teal
        let p = Palette.extract(rgba: image([(90, 15, 20)], each: 500) + image([(14, 18, 24)], each: 1500))
        XCTAssertEqual(p.count, 2, p.map(\.hex).joined(separator: " "))
        XCTAssertTrue(p[0].hsv.h < 0.05 || p[0].hsv.h > 0.93, p[0].hex)
        XCTAssertLessThan(p[1].hsv.s, 0.15, "second should be the tinted white, got \(p[1].hex)")
    }

    func testGreyArtGivesWhites() {
        XCTAssertEqual(Palette.extract(rgba: image([(128, 128, 128)], each: 1000)), Palette.whites)
    }

    func testRareHueIsIgnored() {
        // a 0.5% speck of green on a blue cover is not a palette color
        let p = Palette.extract(rgba: image([(30, 60, 210)], each: 995) + image([(20, 220, 40)], each: 5))
        XCTAssertEqual(p.count, 2, p.map(\.hex).joined(separator: " "))
        XCTAssertFalse(p.contains { abs($0.hsv.h - 0.36) < 0.08 && $0.hsv.s > 0.3 }, "the green speck was picked")
    }

    func testPicksAreSpreadInHue() {
        // two near-identical blues and an orange: expect blue + orange, not blue + blue
        let p = Palette.extract(rgba: image([(30, 60, 210), (40, 80, 230), (240, 140, 30)], each: 500))
        XCTAssertEqual(p.count, 2, p.map(\.hex).joined(separator: " "))
    }

    func testTinyOrTransparentImageFallsBack() {
        XCTAssertEqual(Palette.extract(rgba: [0, 0, 0, 0]), Palette.fallback)
    }

    func testHexRoundTrip() {
        XCTAssertEqual(RGB(hex: "#1DB954")?.hex, "#1DB954")
        XCTAssertNil(RGB(hex: "zz"))
    }
}

final class GeometryTests: XCTestCase {
    // 14" MacBook Pro at default scaling: 1512×982 pt, menu bar areas either side of the camera.
    let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let left = CGRect(x: 0, y: 950, width: 661, height: 32)
    let right = CGRect(x: 851, y: 950, width: 661, height: 32)

    func testNotchFromAuxiliaryAreas() {
        let n = RimGeometry.notch(screenFrame: frame, topLeftArea: left, topRightArea: right)
        XCTAssertEqual(n, CGRect(x: 661, y: 0, width: 190, height: 32))
        XCTAssertNil(RimGeometry.notch(screenFrame: frame, topLeftArea: nil, topRightArea: right))
    }

    func testStripsCoverOnlyTheEdgesWithoutOverlap() {
        let g = RimGeometry(size: frame.size, cornerRadius: 10, notch: CGRect(x: 661, y: 0, width: 190, height: 32))
        let s = g.strips(band: 60)
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s[0].height, 92)                     // top strip wraps the notch
        let area = s.reduce(0) { $0 + $1.width * $1.height }
        XCTAssertLessThan(area, frame.width * frame.height * 0.3)
        for i in 0..<s.count { for j in (i + 1)..<s.count { XCTAssertTrue(s[i].intersection(s[j]).isEmpty || s[i].intersection(s[j]).width * s[i].intersection(s[j]).height == 0) } }
        // together they reach every edge
        XCTAssertEqual(s.map(\.minX).min(), 0); XCTAssertEqual(s.map(\.maxX).max(), 1512)
        XCTAssertEqual(s.map(\.minY).min(), 0); XCTAssertEqual(s.map(\.maxY).max(), 982)
    }

    func testWindowFrameFlipsToAppKit() {
        let second = CGRect(x: 1512, y: -98, width: 1920, height: 1080)   // iMac screen to the right
        let f = RimGeometry.windowFrame(strip: CGRect(x: 0, y: 0, width: 1920, height: 60), screenFrame: second)
        XCTAssertEqual(f, CGRect(x: 1512, y: 922, width: 1920, height: 60))
    }
}

final class SettingsAndCommandTests: XCTestCase {
    func testCommandsParseAndApply() {
        var s = RimSettings()
        XCTAssertEqual(Command.parse(["off"]), .off)
        Command.parse(["off"])!.apply(to: &s); XCTAssertFalse(s.enabled)
        Command.parse(["toggle"])!.apply(to: &s); XCTAssertTrue(s.enabled)
        XCTAssertEqual(Command.parse(["motion", "Steady"]), .motion(.steady))
        Command.parse(["brightness", "150"])!.apply(to: &s); XCTAssertEqual(s.brightness, 1)
        Command.parse(["glow", "999"])!.apply(to: &s); XCTAssertEqual(s.glow, 240)
        Command.parse(["strength", "90"])!.apply(to: &s); XCTAssertEqual(s.reactivity, 0.9, accuracy: 1e-9)
        XCTAssertEqual(Command.parse(["lyrics", "off"]), .lyrics(false))
        XCTAssertNil(Command.parse(["motion", "disco"]))
        XCTAssertNil(Command.parse(["nonsense"]))
        XCTAssertNil(Command.parse([]))
    }

    func testOldSettingsFileStillLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rim-\(UUID()).json")
        try #"{"enabled": false, "glow": 12, "unknownKey": 3}"#.data(using: .utf8)!.write(to: url)
        let s = RimSettings.load(from: url)
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.glow, 12)
        XCTAssertEqual(s.motion, .beat)
        try s.save(to: url)
        XCTAssertEqual(RimSettings.load(from: url), s)
    }
}

final class PlaybackClockTests: XCTestCase {
    func testJitterIsSmoothedButSeeksJump() {
        var c = PlaybackClock(progressMs: 10_000, reportedAt: 0, paused: false)
        c.update(progressMs: 15_040, reportedAt: 5_000, paused: false)       // 40 ms of jitter
        XCTAssertEqual(c.position(at: 5_000), 15_010, accuracy: 0.01)        // a quarter of it
        c.update(progressMs: 60_000, reportedAt: 6_000, paused: false)       // a seek
        XCTAssertEqual(c.position(at: 6_000), 60_000, accuracy: 0.01)
        c.update(progressMs: 61_000, reportedAt: 7_000, paused: true)        // pause takes the report
        XCTAssertTrue(c.paused)
        XCTAssertEqual(c.position(at: 9_000), 61_000, accuracy: 0.01)
    }
}

final class BridgeTests: XCTestCase {
    func testDecodesExtensionMessages() {
        let track = ##"{"type":"track","uri":"spotify:track:1","name":"Song","artist":"A","image":"https://i.scdn.co/image/x","durationMs":180000,"colors":{"VIBRANT":"#FF0000"}}"##
        guard case .track(let t)? = BridgeMessage.decode(Data(track.utf8)) else { return XCTFail() }
        XCTAssertEqual(t.name, "Song"); XCTAssertEqual(t.colors?["VIBRANT"], "#FF0000")

        let state = #"{"type":"state","paused":false,"progressMs":1234,"sentAt":99}"#
        XCTAssertEqual(BridgeMessage.decode(Data(state.utf8)), .state(paused: false, progressMs: 1234, sentAt: 99))

        let lyr = #"{"type":"lyrics","uri":"u","synced":true,"lines":[{"t":100,"w":"hi"}]}"#
        XCTAssertEqual(BridgeMessage.decode(Data(lyr.utf8)), .lyrics(uri: "u", synced: true, lines: [LyricLine(t: 100, w: "hi")]))

        let an = #"{"type":"analysis","uri":"u","tempo":120,"beats":[[0.5,0.9],[1.0,0.4]],"bars":[0.5]}"#
        XCTAssertEqual(BridgeMessage.decode(Data(an.utf8)), .analysis(uri: "u", tempo: 120, beats: [0.5, 1.0], confidence: [0.9, 0.4], bars: [0.5]))

        let full = #"{"type":"analysis","uri":"u","tempo":120,"beats":[[0.5,0.9]],"bars":[0.5],"sections":[[0,30,-9.5]],"loudness":[-7.25]}"#
        XCTAssertEqual(BridgeMessage.decode(Data(full.utf8)),
                       .analysis(uri: "u", tempo: 120, beats: [0.5], confidence: [0.9], bars: [0.5],
                                 sections: [.init(start: 0, duration: 30, loudness: -9.5)], loudness: [-7.25]))

        XCTAssertNil(BridgeMessage.decode(Data("not json".utf8)))
        XCTAssertNil(BridgeMessage.decode(Data(#"{"type":"state"}"#.utf8)))
    }
}
