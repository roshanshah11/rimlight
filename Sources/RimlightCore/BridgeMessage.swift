import Foundation

/// Messages the Spicetify extension (spicetify/rimlight-bridge.js) sends over ws://127.0.0.1:47811.
public enum BridgeMessage: Equatable, Sendable {
    case hello(version: Int)
    case track(Track)
    case state(paused: Bool, progressMs: Double, sentAt: Double)
    case lyrics(uri: String, synced: Bool, lines: [LyricLine])
    /// Spotify's audio analysis: beats (with confidence), bar starts, and when the bridge sends them, sections
    /// (start, duration, loudness dB) and each beat's loudness (dB, its loudest segment).
    case analysis(uri: String, tempo: Double, beats: [Double], confidence: [Float], bars: [Double],
                  sections: [SongAnalysis.SongSection] = [], loudness: [Double] = [])
    case unavailable(kind: String, uri: String)

    public struct Track: Codable, Equatable, Sendable {
        public var uri: String
        public var name: String?
        public var artist: String?
        public var album: String?
        public var image: String?
        public var durationMs: Double?
        public var colors: [String: String]?

        public init(uri: String, name: String? = nil, artist: String? = nil, album: String? = nil, image: String? = nil,
                    durationMs: Double? = nil, colors: [String: String]? = nil) {
            self.uri = uri; self.name = name; self.artist = artist; self.album = album
            self.image = image; self.durationMs = durationMs; self.colors = colors
        }
    }

    public static let port: UInt16 = 47811

    private struct Envelope: Decodable {
        var type: String
        var version: Int?
        var paused: Bool?
        var progressMs: Double?
        var sentAt: Double?
        var uri: String?
        var synced: Bool?
        var lines: [LyricLine]?
        var tempo: Double?
        var beats: [[Double]]?
        var bars: [Double]?
        var sections: [[Double]]?
        var loudness: [Double]?
        var kind: String?
    }

    public static func decode(_ data: Data) -> BridgeMessage? {
        guard let e = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        switch e.type {
        case "hello": return .hello(version: e.version ?? 0)
        case "track": return (try? JSONDecoder().decode(Track.self, from: data)).map(BridgeMessage.track)
        case "state":
            guard let p = e.progressMs else { return nil }
            return .state(paused: e.paused ?? true, progressMs: p, sentAt: e.sentAt ?? Date().timeIntervalSince1970 * 1000)
        case "lyrics":
            guard let uri = e.uri else { return nil }
            return .lyrics(uri: uri, synced: e.synced ?? false, lines: e.lines ?? [])
        case "analysis":
            guard let uri = e.uri, let beats = e.beats else { return nil }
            let pairs = beats.filter { !$0.isEmpty }
            let secs = (e.sections ?? []).filter { $0.count >= 3 }.map { SongAnalysis.SongSection(start: $0[0], duration: $0[1], loudness: $0[2]) }
            return .analysis(uri: uri, tempo: e.tempo ?? 0, beats: pairs.map { $0[0] },
                             confidence: pairs.map { $0.count > 1 ? Float($0[1]) : 1 }, bars: e.bars ?? [],
                             sections: secs, loudness: e.loudness ?? [])
        case "unavailable":
            return .unavailable(kind: e.kind ?? "", uri: e.uri ?? "")
        default: return nil
        }
    }
}
