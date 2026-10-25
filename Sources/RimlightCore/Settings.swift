import Foundation

public enum Motion: String, Codable, CaseIterable, Sendable { case beat, flow, steady }
public enum ColorSource: String, Codable, CaseIterable, Sendable { case album, custom }

/// Everything the menu and the CLI can change. Stored as JSON in ~/Library/Application Support/Rimlight.
public struct RimSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var motion: Motion = .beat
    public var colorSource: ColorSource = .album
    public var customColors = ["#8B5CFF", "#2E9BFF", "#FF5CB8"]
    public var brightness = 0.85        // 0...1
    public var thickness = 5.0          // points, core line
    public var glow = 100.0             // points, how far the light blooms in
    public var reactivity = 0.9         // 0...1, how hard beats hit
    public var hdr = true               // brighter-than-white beat peaks on XDR screens
    public var wrapNotch = true
    public var lyrics = false           // off: Spicy Lyrics already shows them full screen
    public var lyricsDisplay = "auto"   // display name, or "auto" (the external screen if there is one)
    public var disabledDisplays: [String] = []
    public var syncOffsetMs = 0.0       // + delays the light, - makes it earlier
    public var streamedFPS = 60.0       // cap for the streamed iMac screen (imac-stream sends up to 60)
    public var idleWhenPaused = true    // fade out when nothing plays
    public var iMacOnly = true          // while the iMac stream is up, light only the iMac
    public var flashes = true           // white hits on drops (never more than 3 a second)
    /// Per output device (its Core Audio UID), ms added to the light's wait, from `rimlight calibrate`: macOS's
    /// reported latency for Bluetooth headphones can be tens of ms off what reaches the ears.
    public var deviceOffsets: [String: Double] = [:]
    /// Pixels per point the glow is drawn at (it's scaled up to the screen; 2 = a Retina screen's own resolution).
    public var renderScale = 1.0
    /// The welcome window was shown (a new install shows it once; a settings file from before it existed counts as
    /// welcomed).
    public var welcomed = false

    public init() {}

    // Decode leniently so a settings file from an older build keeps working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RimSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        enabled = v(.enabled, d.enabled)
        motion = v(.motion, d.motion)
        colorSource = v(.colorSource, d.colorSource)
        customColors = v(.customColors, d.customColors)
        brightness = v(.brightness, d.brightness)
        thickness = v(.thickness, d.thickness)
        glow = v(.glow, d.glow)
        reactivity = v(.reactivity, d.reactivity)
        hdr = v(.hdr, d.hdr)
        wrapNotch = v(.wrapNotch, d.wrapNotch)
        lyrics = v(.lyrics, d.lyrics)
        lyricsDisplay = v(.lyricsDisplay, d.lyricsDisplay)
        disabledDisplays = v(.disabledDisplays, d.disabledDisplays)
        syncOffsetMs = v(.syncOffsetMs, d.syncOffsetMs)
        streamedFPS = v(.streamedFPS, d.streamedFPS)
        idleWhenPaused = v(.idleWhenPaused, d.idleWhenPaused)
        iMacOnly = v(.iMacOnly, d.iMacOnly)
        flashes = v(.flashes, d.flashes)
        deviceOffsets = v(.deviceOffsets, d.deviceOffsets)
        renderScale = v(.renderScale, d.renderScale)
        welcomed = v(.welcomed, true)
        clamp()
    }

    public mutating func clamp() {
        brightness = min(1, max(0, brightness))
        thickness = min(30, max(1, thickness))
        glow = min(240, max(0, glow))
        reactivity = min(1, max(0, reactivity))
        syncOffsetMs = min(500, max(-500, syncOffsetMs))
        streamedFPS = min(120, max(10, streamedFPS))
        deviceOffsets = deviceOffsets.mapValues { min(400, max(-400, $0)) }
        renderScale = min(2, max(0.25, renderScale))
    }

    /// The strip band: wide enough for the core line plus the visible part of the halo.
    public var band: Double { thickness + glow * 2.3 + 4 }

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Rimlight", isDirectory: true)
    }
    public static var fileURL: URL { directory.appendingPathComponent("settings.json") }
    public static var statusURL: URL { directory.appendingPathComponent("status.json") }

    public static func load(from url: URL = fileURL) -> RimSettings {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(RimSettings.self, from: data)
        else { return RimSettings() }
        return s
    }

    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
