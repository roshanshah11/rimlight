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
    public var glow = 48.0              // points, halo spread
    public var reactivity = 0.7         // 0...1, how hard beats hit
    public var hdr = true               // brighter-than-white beat peaks on XDR screens
    public var wrapNotch = true
    public var lyrics = true
    public var lyricsDisplay = "auto"   // display name, or "auto" (the external screen if there is one)
    public var disabledDisplays: [String] = []
    public var syncOffsetMs = 0.0       // + delays the light, - makes it earlier
    public var streamedFPS = 30.0       // cap for virtual / streamed displays
    public var idleWhenPaused = true    // fade out when nothing plays

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
        clamp()
    }

    public mutating func clamp() {
        brightness = min(1, max(0, brightness))
        thickness = min(30, max(1, thickness))
        glow = min(200, max(0, glow))
        reactivity = min(1, max(0, reactivity))
        syncOffsetMs = min(500, max(-500, syncOffsetMs))
        streamedFPS = min(120, max(10, streamedFPS))
    }

    /// The strip band: wide enough for the core line plus the visible part of the halo.
    public var band: Double { thickness + glow * 1.6 + 4 }

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
