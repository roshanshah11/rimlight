import Foundation
import Network
import RimlightCore

/// Receives the Spicetify extension's messages on ws://127.0.0.1:47811 (loopback only; a browser page from any
/// other origin is refused at the handshake). Without the extension, Spotify's own PlaybackStateChanged
/// distributed notification still gives the track and play state, with no permission prompt.
final class SpotifyBridge {
    var onMessage: ((BridgeMessage) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    private(set) var connected = false

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.roshan.rimlight.bridge")

    func start() {
        listen()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, !self.connected, let info = note.userInfo else { return }
            for m in Self.messages(fromNotification: info) { self.onMessage?(m) }
        }
    }

    private func listen() {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.setClientRequestHandler(queue) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value.lowercased() ?? ""
            let ok = origin.isEmpty || origin.hasSuffix(".spotify.com") || origin.hasPrefix("https://xpui.app.spotify.com")
            return NWProtocolWebSocket.Response(status: ok ? .accept : .reject, subprotocol: nil)
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        // bind to 127.0.0.1 itself, not every interface (lsof showed *:47811 with the interface rule alone)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: BridgeMessage.port)!)
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.listener?.cancel()
                    self?.queue.asyncAfter(deadline: .now() + 3) { self?.listen() }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            NSLog("Rimlight bridge: cannot listen on \(BridgeMessage.port): \(error)")
        }
    }

    private func accept(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        connections[id] = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.setConnected(true)
            case .failed, .cancelled:
                self.connections[id] = nil
                self.setConnected(!self.connections.isEmpty)
            default: break
            }
        }
        c.start(queue: queue)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .close {
                c.cancel(); return
            }
            if let data, !data.isEmpty, let msg = BridgeMessage.decode(data) {
                DispatchQueue.main.async { self.onMessage?(msg) }
            }
            if error == nil { self.receive(c) } else { c.cancel() }
        }
    }

    private func setConnected(_ on: Bool) {
        DispatchQueue.main.async {
            guard on != self.connected else { return }
            self.connected = on
            self.onConnectionChange?(on)
        }
    }

    /// Spotify's notification: "Track ID", "Name", "Artist", "Album", "Duration" (ms), "Player State",
    /// "Playback Position" (seconds).
    static func messages(fromNotification info: [AnyHashable: Any]) -> [BridgeMessage] {
        guard let uri = info["Track ID"] as? String else { return [] }
        let duration = (info["Duration"] as? NSNumber)?.doubleValue
        let track = BridgeMessage.Track(uri: uri, name: info["Name"] as? String, artist: info["Artist"] as? String,
                                        album: info["Album"] as? String, image: nil, durationMs: duration, colors: nil)
        let paused = (info["Player State"] as? String) != "Playing"
        let pos = ((info["Playback Position"] as? NSNumber)?.doubleValue ?? 0) * 1000
        return [.track(track), .state(paused: paused, progressMs: pos, sentAt: Date().timeIntervalSince1970 * 1000)]
    }
}
