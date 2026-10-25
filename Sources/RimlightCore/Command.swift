import Foundation

/// `rimlight <command>`: the CLI edits settings.json and pings the running app.
public enum Command: Equatable, Sendable {
    case on, off, toggle, status, help
    case motion(Motion)
    case brightness(Double)    // 0...1
    case strength(Double)      // 0...1, how hard beats hit
    case glow(Double)
    case thickness(Double)
    case lyrics(Bool)
    case offset(Double)        // ms
    case debugRender(String)   // png path

    public static let usage = """
    usage: rimlight on | off | toggle | status | version
           rimlight motion beat|flow|steady
           rimlight brightness 0-100 | strength 0-100 | glow <pt> | thickness <pt>
           rimlight lyrics on|off | offset <ms>
           rimlight calibrate   (line the light up with your current speakers or headphones)
           rimlight check-update | spotify-extension
           rimlight debug-render <file.png>
    """

    public static func parse(_ args: [String]) -> Command? {
        guard let first = args.first?.lowercased() else { return nil }
        let rest = Array(args.dropFirst())
        func num() -> Double? { rest.first.flatMap { Double($0) } }
        func flag() -> Bool? {
            switch rest.first?.lowercased() {
            case "on", "true", "1", "yes": return true
            case "off", "false", "0", "no": return false
            default: return nil
            }
        }
        switch first {
        case "on", "start": return .on
        case "off", "stop": return .off
        case "toggle": return .toggle
        case "status": return .status
        case "help", "-h", "--help": return .help
        case "motion", "mode": return rest.first.flatMap { Motion(rawValue: $0.lowercased()) }.map(Command.motion)
        case "brightness": return num().map { .brightness(min(100, max(0, $0)) / 100) }
        case "strength", "reactivity": return num().map { .strength(min(100, max(0, $0)) / 100) }
        case "glow": return num().map(Command.glow)
        case "thickness": return num().map(Command.thickness)
        case "lyrics": return flag().map(Command.lyrics)
        case "offset", "sync": return num().map(Command.offset)
        case "debug-render": return rest.first.map(Command.debugRender)
        default: return nil
        }
    }

    /// Apply to settings; false for commands that don't change settings.
    @discardableResult
    public func apply(to s: inout RimSettings) -> Bool {
        switch self {
        case .on: s.enabled = true
        case .off: s.enabled = false
        case .toggle: s.enabled.toggle()
        case .motion(let m): s.motion = m
        case .brightness(let b): s.brightness = b
        case .strength(let r): s.reactivity = r
        case .glow(let g): s.glow = g
        case .thickness(let t): s.thickness = t
        case .lyrics(let on): s.lyrics = on
        case .offset(let ms): s.syncOffsetMs = ms
        case .status, .help, .debugRender: return false
        }
        s.clamp()
        return true
    }
}
