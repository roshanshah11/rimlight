import AppKit
import ImageIO
import RimlightCore
import UniformTypeIdentifiers

/// `rimlight <command>`: edits settings.json, then pings the running app to reload it.
enum CLI {
    static let reloadNote = Notification.Name("com.roshan.rimlight.reload")

    static func run(_ args: [String]) -> Int32 {
        guard let cmd = Command.parse(args) else {
            FileHandle.standardError.write(Data((Command.usage + "\n").utf8))
            return 2
        }
        switch cmd {
        case .help:
            print(Command.usage)
        case .status:
            printStatus()
        case .debugRender(let path):
            let pulse = Float(args.dropFirst(2).first.flatMap(Double.init) ?? 0.8)
            return debugRender(to: path, pulse: pulse) ? 0 : 1
        default:
            var s = RimSettings.load()
            cmd.apply(to: &s)
            do { try s.save() } catch {
                FileHandle.standardError.write(Data("rimlight: cannot save settings: \(error)\n".utf8))
                return 1
            }
            DistributedNotificationCenter.default().postNotificationName(reloadNote, object: nil, userInfo: nil,
                                                                         deliverImmediately: true)
            print(summary(s))
        }
        return 0
    }

    static func summary(_ s: RimSettings) -> String {
        "\(s.enabled ? "on" : "off"), motion \(s.motion.rawValue), brightness \(Int(s.brightness * 100)), "
            + "glow \(Int(s.glow)) pt, thickness \(Int(s.thickness)) pt, reactivity \(Int(s.reactivity * 100)), "
            + "lyrics \(s.lyrics ? "on" : "off"), offset \(Int(s.syncOffsetMs)) ms"
    }

    static func printStatus() {
        let s = RimSettings.load()
        guard let data = try? Data(contentsOf: RimSettings.statusURL),
              let st = try? JSONDecoder().decode(Status.self, from: data) else {
            print("Rimlight is not running.\nsettings: \(summary(s))")
            return
        }
        let age = Date().timeIntervalSince1970 - st.updatedAt
        if age > 5 { print("Rimlight is not running (last seen \(Int(age)) s ago).") }
        print("song:    \(st.song ?? "nothing playing")")
        print("glow:    \(st.lit ? "lit" : "idle")\(st.enabled ? "" : " (turned off)")")
        print("beats:   \(st.beatSource)\(st.tempo.map { String(format: ", %.0f BPM", $0) } ?? "")")
        print("audio:   \(st.audio)")
        print("screens: \(st.screens.isEmpty ? "none" : st.screens.joined(separator: ", "))")
        if let l = st.lyrics { print("lyrics:  \(l)") }
        print("settings: \(summary(s))")
    }

    /// Render a preview of a 14-inch MacBook screen (notch included) at `pulse`, over a dark desktop.
    static func debugRender(to path: String, pulse: Float) -> Bool {
        let s = RimSettings.load()
        let size = CGSize(width: 1512, height: 982)
        let notch = CGRect(x: (1512 - 185) / 2, y: 0, width: 185, height: 32)
        let geo = RimGeometry(size: size, cornerRadius: 10, notch: s.wrapNotch ? notch : nil)
        do {
            let r = try GlowRenderer()
            let colors = s.colorSource == .custom ? s.customColors.compactMap(RGB.init(hex:)) : Palette.fallback
            let frame = GlowFrame(geometry: geo, scale: 2, thickness: Float(s.thickness), reach: Float(s.glow),
                                  brightness: Float(s.brightness), fade: 1, pulse: pulse, energy: 0.6, time: 0,
                                  headroom: 1, colors: colors.map(\.linearSIMD))
            guard let img = r.renderImage(frame, background: RGB(0.11, 0.11, 0.13)) else { return false }
            let url = URL(fileURLWithPath: path) as CFURL
            guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(dest, img, nil)
            let ok = CGImageDestinationFinalize(dest)
            print(ok ? "wrote \(path)" : "could not write \(path)")
            return ok
        } catch {
            FileHandle.standardError.write(Data("rimlight: \(error)\n".utf8))
            return false
        }
    }
}

/// What the running app reports to `rimlight status` (status.json, rewritten every second).
struct Status: Codable {
    var updatedAt: Double
    var enabled: Bool
    var lit: Bool
    var song: String?
    var beatSource: String
    var tempo: Double?
    var audio: String
    var screens: [String]
    var lyrics: String?
}
