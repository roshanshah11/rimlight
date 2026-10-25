import AppKit
import CoreImage
import CoreText
import ImageIO
import RimlightCore
import UniformTypeIdentifiers

/// `rimlight <command>`: edits settings.json, then pings the running app to reload it.
enum CLI {
    static let reloadNote = Notification.Name("com.roshan.rimlight.reload")
    static let calibrateNote = Notification.Name("com.roshan.rimlight.calibrate")
    static let litNote = Notification.Name("com.roshan.rimlight.debug-lit")

    static func run(_ args: [String]) -> Int32 {
        if ["version", "--version", "-v"].contains(args.first ?? "") { print("Rimlight \(version)"); return 0 }
        if args.first == "debug-welcome", args.count >= 2 { return debugWelcome(to: args[1]) ? 0 : 1 }
        if args.first == "debug-tap-level" { return debugTapLevel(seconds: Double(args.dropFirst().first ?? "") ?? 3) }
        if args.first == "palette", args.count >= 3 { return paletteSheet(out: args[1], images: Array(args.dropFirst(2))) ? 0 : 1 }
        if args.first == "debug-plan", args.count >= 2 { return debugPlan(args[1]) ? 0 : 1 }
        if args.first == "debug-tap-compare", args.count >= 2 { return debugTapCompare(to: args[1]) ? 0 : 1 }
        if args.first == "debug-lit" {
            DistributedNotificationCenter.default().postNotificationName(litNote, object: args.count > 1 ? args[1] : "5",
                                                                         userInfo: nil, deliverImmediately: true)
            return 0
        }
        if args.first == "calibrate" {
            // `rimlight calibrate` starts; `calibrate earlier|later|save|stop` drives it without the panel
            let step = args.count > 1 ? args[1] : "start"
            guard ["start", "earlier", "later", "save", "stop", "manual", "selfcheck"].contains(step) else {
                print("usage: rimlight calibrate [manual|earlier|later|save|stop|selfcheck]"); return 2
            }
            if step == "selfcheck" {
                let url = RimSettings.directory.appendingPathComponent("chirp-selfcheck.json")
                try? FileManager.default.removeItem(at: url)
                DistributedNotificationCenter.default().postNotificationName(calibrateNote, object: step, userInfo: nil, deliverImmediately: true)
                for _ in 0..<40 {
                    Thread.sleep(forTimeInterval: 0.25)
                    if let d = try? Data(contentsOf: url) { print(String(decoding: d, as: UTF8.self)); return 0 }
                }
                print("no result (is Rimlight running, and does it have the microphone?)"); return 1
            }
            DistributedNotificationCenter.default().postNotificationName(calibrateNote, object: step, userInfo: nil, deliverImmediately: true)
            if step == "start" { print("Rimlight's timing panel is open: headphones, hold an earcup to your Mac, then press Start.") }
            if step == "manual" {
                print("Clicks are playing in your current output with a flash on the rim: Later/Earlier in the panel (or rimlight calibrate later|earlier), then Save (or rimlight calibrate save). rimlight calibrate stop cancels.")
            }
            return 0
        }
        if args.first == "debug-video", args.count >= 2 {
            let mode: ShowSimulator.Mode = args.contains("--live") ? .predictive : .planned
            func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            return debugVideo(to: args[1], mode: mode, cover: value("--cover"), song: value("--song") ?? "club") ? 0 : 1
        }
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

    /// "1.0.0 (57)" from the app's Info.plist; the CLI runs as the app's own binary (~/bin/rimlight links to it).
    static var version: String {
        var buf = [CChar](repeating: 0, count: 4096)
        let path = proc_pidpath(getpid(), &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : CommandLine.arguments[0]
        let exe = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let plist = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        let info = Bundle.main.infoDictionary?["CFBundleShortVersionString"] != nil ? Bundle.main.infoDictionary
            : NSDictionary(contentsOf: plist) as? [String: Any]
        guard let v = info?["CFBundleShortVersionString"] as? String else { return "(not in an app bundle)" }
        return info?["CFBundleVersion"].map { "\(v) (\($0))" } ?? v
    }

    /// The welcome window, drawn offscreen to a PNG (checks its layout without showing it).
    static func debugWelcome(to path: String) -> Bool {
        _ = NSApplication.shared
        let view = Welcome().makeView()
        view.appearance = NSAppearance(named: .aqua)
        let size = view.fittingSize
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return false }
        print("\(Int(size.width))x\(Int(size.height)) -> \(path)")
        return true
    }

    /// Listen to whatever is playing for a few seconds and print its level: checks that the tap works in this build
    /// (signing, hardened runtime, permission). Tap-only, so Bluetooth headphones stay in stereo. Run it through
    /// LaunchServices so macOS asks for Rimlight, not the terminal:
    /// open -n -W -a Rimlight --args debug-tap-level 3 (it writes tap-level.json beside the settings).
    static func debugTapLevel(seconds: Double) -> Int32 {
        let players = AudioTap.players()
        let url = RimSettings.directory.appendingPathComponent("tap-level.json")
        func report(_ d: [String: Any]) -> Int32 {
            if let data = try? JSONSerialization.data(withJSONObject: d) { try? data.write(to: url); print(String(decoding: data, as: UTF8.self)) }
            return d["error"] == nil ? 0 : 1
        }
        guard !players.isEmpty else { return report(["error": "nothing is playing"]) }
        let tap = AudioTap()
        let lock = NSLock()
        var sum = 0.0, count = 0, peak: Float = 0
        tap.onSamples = { buf, _, _ in
            lock.lock(); defer { lock.unlock() }
            for x in buf { sum += Double(x * x); peak = max(peak, abs(x)) }
            count += buf.count
        }
        do { try tap.start(processes: players) } catch { return report(["error": "\(error)"]) }
        Thread.sleep(forTimeInterval: min(10, seconds))
        tap.stop()
        lock.lock(); defer { lock.unlock() }
        return report(["apps": players.map(\.name), "samples": count, "rms": count > 0 ? (sum / Double(count)).squareRoot() : 0,
                       "peak": peak, "heardSound": tap.heardSound])
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
        if let s = st.show { print("look:    \(s)") }
        print("beats:   \(st.beatSource)\(st.tempo.map { String(format: ", %.0f BPM", $0) } ?? "")")
        print("audio:   \(st.audio)")
        if let t = st.timing { print("timing:  \(t)") }
        print("screens: \(st.screens.isEmpty ? "none" : st.screens.joined(separator: ", "))")
        if let c = st.colors { print("colors:  \(c.joined(separator: " "))") }
        if let l = st.lyrics { print("lyrics:  \(l)") }
        print("settings: \(summary(s))")
    }

    /// Preview the show on a 14-inch MacBook screen (notch included): a synthetic song at 120 BPM (16 s quiet, 16 s
    /// rising, then the drop) runs through the director, and six moments are drawn into one contact sheet.
    /// Colors are the running app's current song colors when it has some.
    static func debugRender(to path: String, pulse _: Float) -> Bool {
        let s = RimSettings.load()
        var colors = Palette.fallback
        if let data = try? Data(contentsOf: RimSettings.statusURL),
           let st = try? JSONDecoder().decode(Status.self, from: data), let c = st.colors?.compactMap(RGB.init(hex:)), !c.isEmpty {
            colors = c
        }
        let size = CGSize(width: 1512, height: 982)
        let notch = CGRect(x: (1512 - 185) / 2, y: 0, width: 185, height: 32)
        let geo = RimGeometry(size: size, cornerRadius: 10, notch: s.wrapNotch ? notch : nil)
        let moments: [(Double, String)] = [(10, "quiet"), (20, "build, early"), (30.6, "build, late"),
                                           (32.55, "drop: the hit"), (40.0, "drop: on the beat"), (40.3, "drop: between beats")]
        do {
            let r = try GlowRenderer()
            let d = ShowDirector(palette: colors)
            d.allowFlashes = s.flashes
            var shots: [(CGImage, String)] = []
            var t = 0.0, nextBeat = 0.5, m = 0
            while m < moments.count {
                if t >= nextBeat { d.beat(at: nextBeat, strength: 0.85); nextBeat += 0.5 }
                let e: Float = t < 16 ? 0.2 : (t < 32 ? Float(0.35 + (t - 16) / 16 * 0.25) : 0.92)
                let l = d.frame(at: t, energy: e, bass: 0.7, treble: t < 32 ? Float(t / 32) : 0.6, tempo: 120)
                if t >= moments[m].0 {
                    let f = GlowFrame(geometry: geo, scale: 1, edge: Float(s.thickness), reach: Float(s.glow),
                                      brightness: Float(s.brightness), fade: 1, headroom: 1, light: l)
                    if let img = r.renderImage(f, background: RGB(0.08, 0.08, 0.1)) {
                        shots.append((img, "\(moments[m].1) (\(l.section.rawValue))"))
                    }
                    m += 1
                }
                t += 1.0 / 120
            }
            // 3 x 2 sheet at half size, captions under each
            let cw = 756, ch = 491, cap = 34
            let ctx = CGContext(data: nil, width: cw * 3, height: (ch + cap) * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: cw * 3, height: (ch + cap) * 2))
            for (i, shot) in shots.enumerated() {
                let x = (i % 3) * cw, y = (1 - i / 3) * (ch + cap) + cap
                ctx.draw(shot.0, in: CGRect(x: x, y: y, width: cw, height: ch))
                let label = NSAttributedString(string: shot.1, attributes: [.font: NSFont.systemFont(ofSize: 18),
                                                                           .foregroundColor: NSColor.white])
                let line = CTLineCreateWithAttributedString(label)
                ctx.textPosition = CGPoint(x: x + 12, y: y - 24)
                CTLineDraw(line, ctx)
            }
            guard let sheet = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return false }
            CGImageDestinationAddImage(dest, sheet, nil)
            let ok = CGImageDestinationFinalize(dest)
            print(ok ? "wrote \(path) (colors \(colors.map(\.hex).joined(separator: " ")))" : "could not write \(path)")
            return ok
        } catch {
            FileHandle.standardError.write(Data("rimlight: \(error)\n".utf8))
            return false
        }
    }
}

extension CLI {
    /// `rimlight debug-video <out.mp4> [--live] [--cover image] [--song club|trap|ballad]`: a synthetic song through
    /// the show (Spotify-style plan by default, the trap's hook as the lyrics would give it; live detection with --live) on a 1920x1080 iMac screen at 60 fps, over a dark backdrop
    /// tinted by the cover's colors (like Spicy Lyrics' background), with the track's audio. The look and bar are
    /// written in the corner so the timing can be checked by eye and ear.
    static func debugVideo(to path: String, mode: ShowSimulator.Mode, cover: String?, song name: String) -> Bool {
        let s = RimSettings.load()
        let trap = SyntheticTrap()
        let song: any TestTrack
        switch name {
        case "trap": song = trap
        case "ballad": song = SyntheticBallad()
        default: song = SyntheticSong()
        }
        let hooks = name == "trap" ? [trap.hookTime..<(trap.hookTime + 8 * trap.bar)] : []
        let colors = cover.flatMap { FileManager.default.contents(atPath: $0) }.flatMap(Artwork.palette(from:)) ?? Palette.fallback
        let w = 1920, h = 1080, fps = 60.0
        let geo = RimGeometry(size: CGSize(width: w, height: h), cornerRadius: 0, notch: nil)
        guard let r = try? GlowRenderer() else { return false }

        // backdrop: the cover blurred and darkened over the whole screen, like Spicy Lyrics' full-screen view
        // (two soft blobs of its colors when there's no cover)
        var backdrop = [UInt8](repeating: 0, count: w * h * 4)
        if let path = cover, let ci = CIImage(contentsOf: URL(fileURLWithPath: path)) {
            let scale = max(CGFloat(w) / ci.extent.width, CGFloat(h) / ci.extent.height) * 1.15
            let blurred = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: 70)
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.18, kCIInputSaturationKey: 1.1])
            let ctx = CIContext()
            let x0 = (ci.extent.width * scale - CGFloat(w)) / 2, y0 = (ci.extent.height * scale - CGFloat(h)) / 2
            backdrop.withUnsafeMutableBytes { buf in
                ctx.render(blurred, toBitmap: buf.baseAddress!, rowBytes: w * 4,
                           bounds: CGRect(x: x0, y: y0, width: CGFloat(w), height: CGFloat(h)),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
            // keep it about as dark as Spicy Lyrics' backdrop (which dims the art behind the lyrics)
            for i in stride(from: 0, to: backdrop.count, by: 4) {
                for c in 0..<3 { backdrop[i + c] = UInt8(Double(backdrop[i + c]) * 0.55) }
                backdrop[i + 3] = 255
            }
        } else {
        let c0 = colors[0], c1 = colors.count > 1 ? colors[1] : colors[0]
        for y in 0..<h {
            for x in 0..<w {
                let fx = Double(x) / Double(w), fy = Double(y) / Double(h)
                let a = exp(-((fx - 0.3) * (fx - 0.3) + (fy - 0.45) * (fy - 0.45)) * 6) * 0.22
                let b = exp(-((fx - 0.75) * (fx - 0.75) + (fy - 0.6) * (fy - 0.6)) * 6) * 0.18
                let i = (y * w + x) * 4
                backdrop[i] = UInt8(min(255, (0.05 + a * c0.r + b * c1.r) * 255))
                backdrop[i + 1] = UInt8(min(255, (0.05 + a * c0.g + b * c1.g) * 255))
                backdrop[i + 2] = UInt8(min(255, (0.06 + a * c0.b + b * c1.b) * 255))
                backdrop[i + 3] = 255
            }
        }
        }

        // the audio, as a WAV beside the video
        let wav = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rimlight-preview.wav")
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let n = UInt32(song.samples.count)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + n * 2); data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(song.sampleRate)); u32(UInt32(song.sampleRate) * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(n * 2)
        for x in song.samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, x)) * 32000))) }
        guard (try? data.write(to: wav)) != nil else { return false }

        let ff = Process()
        ff.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        ff.arguments = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(w)x\(h)",
                        "-r", "60", "-i", "-", "-i", wav.path, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18",
                        "-preset", "medium", "-c:a", "aac", "-b:a", "192k", "-shortest", path]
        let pipe = Pipe()
        ff.standardInput = pipe
        do { try ff.run() } catch { print("rimlight: ffmpeg: \(error)"); return false }

        var px = [UInt8]()
        let font = NSFont.monospacedSystemFont(ofSize: 22, weight: .medium)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var frames = 0
        _ = ShowSimulator.run(song, mode: mode, fps: fps, palette: colors, hooks: hooks, startStyle: .hiphop,
                              latency: 0.05) { t, light, style in
            let f = GlowFrame(geometry: geo, scale: 1, edge: Float(s.thickness), reach: Float(s.glow),
                              brightness: Float(s.brightness), fade: 1, headroom: 1, light: light)
            r.renderPixels(f, backdrop: backdrop, into: &px)
            px.withUnsafeMutableBytes { buf in
                if let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                       space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                    let bar = Int(t / song.bar) + 1
                    let beat = Int((t.truncatingRemainder(dividingBy: song.bar)) / song.beat) + 1
                    let text = "\(style.name(light.section).uppercased())   \(style.label)   bar \(bar) beat \(beat)   \(mode == .planned ? "planned" : "live")"
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                        .font: font, .foregroundColor: NSColor(white: 1, alpha: 0.75)]))
                    ctx.textPosition = CGPoint(x: 160, y: CGFloat(h) - 200)
                    CTLineDraw(line, ctx)
                }
                pipe.fileHandleForWriting.write(Data(buf))
            }
            frames += 1
        }
        pipe.fileHandleForWriting.closeFile()
        ff.waitUntilExit()
        try? FileManager.default.removeItem(at: wav)
        print(ff.terminationStatus == 0 ? "wrote \(path) (\(frames) frames, colors \(colors.map(\.hex).joined(separator: " ")))" : "ffmpeg failed")
        return ff.terminationStatus == 0
    }

    /// `rimlight debug-plan <analysis.json>`: a Spotify audio-analysis file through SongPlan, the same way the bridge
    /// feeds it (each beat's loudness = its loudest overlapping segment). Prints the plan bar by bar per section.
    static func debugPlan(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let a = (root["analysis"] as? [String: Any]) ?? root
        func list(_ k: String) -> [[String: Any]] { a[k] as? [[String: Any]] ?? [] }
        func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        let beats = list("beats"), segs = list("segments")
        let tempo = num(a["track"] as? [String: Any] ?? [:], "tempo")
        var j = 0
        let loud: [Double] = beats.map { b in
            let start = num(b, "start"), end = start + max(num(b, "duration"), 0.05)
            while j < segs.count, num(segs[j], "start") + num(segs[j], "duration") <= start { j += 1 }
            var best = -60.0
            var k = j
            while k < segs.count, num(segs[k], "start") < end { best = max(best, num(segs[k], "loudness_max")); k += 1 }
            return best
        }
        let analysis = SongAnalysis(tempo: tempo, beats: beats.map { num($0, "start") }, bars: list("bars").map { num($0, "start") },
                                    sections: list("sections").map { .init(start: num($0, "start"), duration: num($0, "duration"), loudness: num($0, "loudness")) },
                                    beatLoudness: loud)
        guard let plan = SongPlan.make(analysis) else { print("no plan"); return false }
        print(String(format: "tempo %.1f, %d beats, %d bars, %d sections; drops at %@", tempo, beats.count, analysis.bars.count,
                     analysis.sections.count, plan.drops.map { String(format: "%.1f s", $0) }.joined(separator: ", ")))
        for sec in analysis.sections {
            let idx = plan.barStarts.indices.filter { plan.barStarts[$0] >= sec.start - 0.05 && plan.barStarts[$0] < sec.start + sec.duration - 0.05 }
            let cues = idx.map { i -> String in
                switch plan.cues[i] {
                case .quiet: return "q"
                case .groove: return "g"
                case .drop: return "D"
                case .build(let p): return p < 0.5 ? "b" : "B"
                }
            }.joined()
            print(String(format: "%6.1f s  %5.1f dB  %@", sec.start, sec.loudness, cues))
        }
        for b in plan.blackouts { print(String(format: "blackout %.2f - %.2f s", b.lowerBound, b.upperBound)) }
        return true
    }

    /// `rimlight palette <sheet.png> <image>...`: each cover beside the light colors Rimlight would pick from it.
    static func paletteSheet(out: String, images: [String]) -> Bool {
        let rowH = 180, thumb = 160, sw = 150, w = 20 + thumb + 20 + 4 * (sw + 10) + 20
        let h = rowH * images.count + 20
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return false }
        ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (i, path) in images.enumerated() {
            let y = h - 20 - (i + 1) * rowH + 10
            guard let data = FileManager.default.contents(atPath: path),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            ctx.draw(img, in: CGRect(x: 20, y: y, width: thumb, height: thumb))
            let colors = Artwork.palette(from: data) ?? []
            print("\((path as NSString).lastPathComponent): \(colors.map(\.hex).joined(separator: " "))")
            for (j, c) in colors.enumerated() {
                let x = 20 + thumb + 20 + j * (sw + 10)
                ctx.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1))
                ctx.fill(CGRect(x: x, y: y + 30, width: sw, height: thumb - 30))
                let label = NSAttributedString(string: c.hex, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                                                                           .foregroundColor: NSColor.white])
                ctx.textPosition = CGPoint(x: x + 4, y: y + 8)
                CTLineDraw(CTLineCreateWithAttributedString(label), ctx)
            }
        }
        guard let sheet = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, sheet, nil)
        return CGImageDestinationFinalize(dest)
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
    var colors: [String]?
    var uri: String?
    var show: String?
    var timing: String?
}
