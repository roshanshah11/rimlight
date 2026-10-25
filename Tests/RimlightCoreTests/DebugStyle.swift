import XCTest
@testable import RimlightCore

/// Prints what the style judge sees on each synthetic genre (RIM_DEBUG=1).
final class DebugStyle: XCTestCase {
    func testPrintStyleEvidence() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RIM_DEBUG"] == nil)
        let tracks: [any TestTrack] = [SyntheticSong(), SyntheticTrap(), SyntheticBallad()]
        for song in tracks {
            let det = BeatDetector(sampleRate: song.sampleRate)
            let beats = song.analysis.beats
            var onsets: [BeatEvent] = []
            var share: [Float] = []
            song.samples.withUnsafeBufferPointer { all in
                var i = 0
                while i + 512 <= all.count {
                    onsets += det.process(UnsafeBufferPointer(rebasing: all[i..<(i + 512)]))
                    _ = det.drainBeats()
                    if i % (512 * 40) == 0 { share.append(det.features.bassShare) }
                    i += 512
                }
            }
            let strong = onsets.filter { $0.strength >= 0.6 }
            let hits = beats.filter { b in strong.contains { abs($0.time - b) < 0.07 } }.count
            let off = strong.filter { o in !beats.contains { abs($0 - o.time) < 0.07 } }.count
            let dur = song.duration
            print(String(format: "%@: %.0f BPM, %d onsets (%d strong), hit rate %.2f, off-beat strong %.2f/s, onsets %.2f/s, mean strength %.2f, bass share median %.1f dB, tempo est %.0f",
                         song.name, song.bpm, onsets.count, strong.count, Double(hits) / Double(beats.count), Double(off) / dur,
                         Double(onsets.count) / dur, onsets.map(\.strength).reduce(0, +) / Float(max(1, onsets.count)),
                         share.sorted()[share.count / 2], det.tempo ?? 0))
        }
    }
}

final class DebugStyleSections: XCTestCase {
    func testPrintSections() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RIM_DEBUG"] == nil)
        let tracks: [any TestTrack] = [SyntheticSong(), SyntheticTrap(), SyntheticBallad()]
        for song in tracks {
            for mode in [ShowSimulator.Mode.predictive, .planned] {
                let r = ShowSimulator.run(song, mode: mode, startStyle: .hiphop)
                var line = ""
                var b = 0.0
                while b < song.duration {
                    let f = r.frames.last { $0.t <= b + song.bar / 2 }
                    let c: String
                    switch f?.state.section { case .quiet: c = "q"; case .groove: c = "g"; case .build: c = "b"; case .drop: c = "D"; default: c = "?" }
                    let st = f?.style == .ambient ? "a" : (f?.style == .club ? "c" : "h")
                    line += c + st + " "
                    b += song.bar
                }
                print("\(song.name) \(mode): \(line)")
                for j in r.judged {
                    let e = j.evidence
                    print(String(format: "   %d beats, felt %.0f BPM, bass share %.1f dB, strong %.2f/s, mean %.2f, kick on beat %.2f, crest %.1f dB -> %@",
                                 e.beats, e.feltBPM, e.bassShare, e.strongPerSecond, e.meanStrength, e.kickOnBeat, e.crest, j.style.rawValue))
                }
            }
        }
    }
}

final class DebugGenrePlans: XCTestCase {
    func testPrintPlans() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RIM_DEBUG"] == nil)
        for song in [SyntheticTrap() as any TestTrack, SyntheticBallad()] {
            let a = song.analysis
            guard let p = SongPlan.make(a) else { continue }
            let cues = p.cues.map { c -> String in
                switch c { case .quiet: return "q"; case .groove: return "g"; case .drop: return "D"; case .build: return "b" }
            }.joined()
            let loud = stride(from: 0, to: a.beatLoudness.count, by: 4).map { String(format: "%.0f", a.beatLoudness[$0]) }.joined(separator: " ")
            print("\(song.name): \(cues)\n  downbeat dB: \(loud)")
        }
    }
}

final class DebugTrapFrames: XCTestCase {
    func testPrintTrapDetails() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RIM_DEBUG"] == nil)
        let s = SyntheticTrap()
        let det = BeatDetector(sampleRate: s.sampleRate)
        var onsets: [BeatEvent] = []
        var lows: [(Double, Float, Float)] = []
        s.samples.withUnsafeBufferPointer { all in
            var i = 0
            while i + 512 <= all.count {
                onsets += det.process(UnsafeBufferPointer(rebasing: all[i..<(i + 512)]))
                _ = det.drainBeats()
                let t = Double(i + 512) / s.sampleRate
                if t > s.dropout.lowerBound - 0.4, t < s.hookTime + 0.3 { lows.append((t, det.features.lowLevel, det.features.level)) }
                i += 512
            }
        }
        for h in s.hits where h >= 6 * s.bar && h < 8 * s.bar {
            let near = onsets.min { abs($0.time - h) < abs($1.time - h) }
            print(String(format: "hit %.3f: onset %+.1f ms strength %.2f", h, ((near?.time ?? 0) - h) * 1000, near?.strength ?? 0))
        }
        for (t, l, lv) in lows where Int(t * 100) % 5 == 0 { print(String(format: "  %.2f lowLevel %.2f level %.2f", t - s.dropout.lowerBound, l, lv)) }
        var prev: Float = 0, prevT = 0.0
        _ = ShowSimulator.run(SyntheticBallad(), mode: .predictive, startStyle: .hiphop) { t, st, _ in
            if abs(st.master - prev) > 0.03, t > 22 { print(String(format: "ballad jump at %.3f (prev %.3f): %.3f -> %.3f, %@, pulse %.2f", t, prevT, prev, st.master, st.section.rawValue, st.pulse)) }
            prev = st.master; prevT = t
        }
    }
}

final class DebugTrapAmbiance: XCTestCase {
    func testPrintAmbianceSpans() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["RIM_DEBUG"] == nil)
        let s = SyntheticTrap()
        let r = ShowSimulator.run(s, mode: .predictive, startStyle: .hiphop)
        var start: Double?
        for f in r.frames {
            if f.ambiance, start == nil { start = f.t }
            if !f.ambiance, let a = start { print(String(format: "ambiance %.1f-%.1f s (bars %.1f-%.1f)", a, f.t, a / s.bar, f.t / s.bar)); start = nil }
        }
        if let a = start { print(String(format: "ambiance %.1f-end (bar %.1f)", a, a / s.bar)) }
    }
}
