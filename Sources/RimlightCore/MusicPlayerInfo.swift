import Foundation

/// Apple Music's now-playing notification (com.apple.Music.playerInfo, posted to every app with no permission
/// prompt): "Name", "Artist", "Album", "Total Time" (ms), "Player State" (Playing, Paused, Stopped) and
/// "PersistentID". It has no playback position, so the show runs on the live beat for Music's songs.
public enum MusicPlayerInfo {
    public static let notification = Notification.Name("com.apple.Music.playerInfo")
    public static let bundleID = "com.apple.Music"
    /// Track URIs for Music's songs start with this (Spotify's are spotify:track:...).
    public static let uriPrefix = "music:"

    public static func messages(from info: [AnyHashable: Any], now: Date = Date()) -> [BridgeMessage] {
        let state = info["Player State"] as? String
        let paused = state != "Playing"
        let sentAt = now.timeIntervalSince1970 * 1000
        let id = (info["PersistentID"] as? NSNumber ?? info["Persistent ID"] as? NSNumber).map { "\($0.int64Value)" }
        let name = info["Name"] as? String
        guard let key = id ?? name.map({ [$0, info["Artist"] as? String ?? ""].joined(separator: "|") }) else {
            // "Stopped" comes with no track at all
            return state == nil ? [] : [.state(paused: true, progressMs: 0, sentAt: sentAt)]
        }
        let track = BridgeMessage.Track(uri: uriPrefix + key, name: name, artist: info["Artist"] as? String,
                                        album: info["Album"] as? String, image: nil,
                                        durationMs: (info["Total Time"] as? NSNumber)?.doubleValue, colors: nil)
        return [.track(track), .state(paused: paused, progressMs: 0, sentAt: sentAt)]
    }
}
