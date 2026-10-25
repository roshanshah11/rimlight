import XCTest
@testable import RimlightCore

final class DebugDirector: XCTestCase {
    func testTrace() throws {
        guard ProcessInfo.processInfo.environment["RIM_DEBUG"] != nil else { throw XCTSkip("set RIM_DEBUG") }
        let d = ShowDirector(palette: Palette.fallback)
        var t = 0.0, next = 0.5, last = Section.quiet
        while t < 40 {
            if t >= next { d.beat(at: next, strength: 0.8); next += 0.5 }
            let e: Float = t < 16 ? 0.2 : (t < 32 ? Float(0.35 + (t - 16) / 16 * 0.25) : 0.92)
            let s = d.frame(at: t, energy: e, bass: 0.7, treble: 0.5, tempo: 120)
            if s.section != last || (t > 31.5 && t < 34 && Int(t * 120) % 30 == 0) {
                print(String(format: "t %.2f %@ -> %@ armed %d dark %.2f", t, last.rawValue, s.section.rawValue, d.debugArmed ? 1 : 0, s.dark))
                last = s.section
            }
            t += 1.0 / 120
        }
    }
}
