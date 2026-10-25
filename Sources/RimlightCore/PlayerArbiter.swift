import Foundation

/// Which player app's messages reach the show when more than one is open (Spotify paused beside Music, say). The
/// app playing owns the show: while it plays, another app's song waits and its pause isn't news. When that app starts
/// playing, its song comes on with the lyrics and analysis held for it.
public struct PlayerArbiter {
    /// The app whose song is on (its bundle ID).
    public private(set) var current: String?
    private var held: [String: [BridgeMessage]] = [:]

    public init() {}

    /// The messages to act on, in order. `playing`: whether the current app's song is playing right now.
    public mutating func receive(_ m: BridgeMessage, from source: String, playing: Bool) -> [BridgeMessage] {
        hold(m, from: source)
        guard source != current else { return [m] }
        let busy = current != nil && playing
        guard case .state(let paused, _, _) = m else {
            guard !busy, case .track = m else { return [] }
            current = source
            return [m]
        }
        if paused, busy { return [] }
        current = source
        return (held[source] ?? []) + [m]
    }

    /// Each app's latest song, with its lyrics and analysis (the latest of each).
    private mutating func hold(_ m: BridgeMessage, from source: String) {
        var list = held[source] ?? []
        switch m {
        case .track(let t):
            if case .track(let old)? = list.first, old.uri == t.uri { list[0] = m } else { list = [m] }
        case .lyrics, .analysis:
            guard !list.isEmpty else { return }
            list.removeAll { Self.kind($0) == Self.kind(m) }
            list.append(m)
        default:
            return
        }
        held[source] = list
    }

    private static func kind(_ m: BridgeMessage) -> Int {
        switch m {
        case .track: 0
        case .state: 1
        case .lyrics: 2
        case .analysis: 3
        default: 4
        }
    }
}
