import Foundation

/// The iMac stream's measured hold: imac-stream writes av-sync.json once a second from both ends' delays (how long
/// sound waits behind its picture, sender + receiver). Rimlight holds the iMac's light that long.
public enum StreamSync {
    /// The hold in seconds, or nil when the file is missing, malformed or more than 5 s old (the stream stopped, or
    /// an older receiver that doesn't report is on the other end).
    public static func hold(from data: Data?, now: Double = Date().timeIntervalSince1970) -> Double? {
        guard let data, let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ms = (d["delayMs"] as? NSNumber)?.doubleValue, let at = (d["at"] as? NSNumber)?.doubleValue,
              now - at < 5, now - at > -5 else { return nil }
        return min(0.4, max(0, ms / 1000))
    }
}
