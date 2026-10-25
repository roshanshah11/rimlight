import XCTest
@testable import RimlightCore

/// Apple Music's notification, and which app's song is on when Spotify and Music are both open.
final class PlayerTests: XCTestCase {
    static let spotify = "com.spotify.client", music = MusicPlayerInfo.bundleID

    func testMusicNotificationBecomesATrackAndAState() {
        let info: [AnyHashable: Any] = ["Name": "Nights", "Artist": "Frank Ocean", "Album": "Blonde", "Total Time": NSNumber(value: 307_000),
                                        "Player State": "Playing", "PersistentID": NSNumber(value: Int64(-4_812_345_678_901))]
        let m = MusicPlayerInfo.messages(from: info, now: Date(timeIntervalSince1970: 100))
        guard m.count == 2, case .track(let t) = m[0], case .state(let paused, _, let sentAt) = m[1] else { return XCTFail("\(m)") }
        XCTAssertEqual(t.uri, "music:-4812345678901")
        XCTAssertEqual(t.name, "Nights")
        XCTAssertEqual(t.artist, "Frank Ocean")
        XCTAssertEqual(t.album, "Blonde")
        XCTAssertEqual(t.durationMs, 307_000)
        XCTAssertFalse(paused)
        XCTAssertEqual(sentAt, 100_000)

        // paused keeps the song; stopped comes with no song at all
        guard case .state(true, _, _)? = MusicPlayerInfo.messages(from: info.merging(["Player State": "Paused"]) { $1 }).last
        else { return XCTFail("paused") }
        XCTAssertEqual(MusicPlayerInfo.messages(from: ["Player State": "Stopped"]).count, 1)
        guard case .state(true, _, _)? = MusicPlayerInfo.messages(from: ["Player State": "Stopped"]).first else { return XCTFail("stopped") }
        XCTAssertTrue(MusicPlayerInfo.messages(from: [:]).isEmpty)
    }

    private func track(_ uri: String) -> BridgeMessage { .track(.init(uri: uri, name: uri)) }
    private func state(_ paused: Bool) -> BridgeMessage { .state(paused: paused, progressMs: 0, sentAt: 0) }

    /// Spotify plays; Music's paused song beside it changes nothing. Music starts: its song comes on. Spotify's
    /// extension sends the analysis for its song meanwhile; when Spotify plays again, its song comes back with it.
    func testThePlayingAppOwnsTheShow() {
        var a = PlayerArbiter()
        XCTAssertEqual(a.receive(track("spotify:track:a"), from: Self.spotify, playing: false), [track("spotify:track:a")])
        XCTAssertEqual(a.receive(state(false), from: Self.spotify, playing: false), [state(false)])
        XCTAssertEqual(a.current, Self.spotify)

        XCTAssertEqual(a.receive(track("music:1"), from: Self.music, playing: true), [], "Spotify is playing")
        XCTAssertEqual(a.receive(state(true), from: Self.music, playing: true), [], "a pause in another app isn't news")
        XCTAssertEqual(a.current, Self.spotify)

        XCTAssertEqual(a.receive(state(false), from: Self.music, playing: true), [track("music:1"), state(false)])
        XCTAssertEqual(a.current, Self.music)

        // Spotify's pause, its next song and that song's analysis wait
        let analysis = BridgeMessage.analysis(uri: "spotify:track:b", tempo: 120, beats: [0.5, 1], confidence: [1, 1], bars: [0.5])
        XCTAssertEqual(a.receive(state(true), from: Self.spotify, playing: true), [])
        XCTAssertEqual(a.receive(track("spotify:track:b"), from: Self.spotify, playing: true), [])
        XCTAssertEqual(a.receive(analysis, from: Self.spotify, playing: true), [])

        // Music pauses (its own news), then Spotify plays: its song comes back with its analysis
        XCTAssertEqual(a.receive(state(true), from: Self.music, playing: true), [state(true)])
        XCTAssertEqual(a.receive(state(false), from: Self.spotify, playing: false), [track("spotify:track:b"), analysis, state(false)])
        XCTAssertEqual(a.current, Self.spotify)
    }

    /// Nothing playing: any app's song is the news.
    func testWithNothingPlayingAnySongComesOn() {
        var a = PlayerArbiter()
        _ = a.receive(track("spotify:track:a"), from: Self.spotify, playing: false)
        _ = a.receive(state(true), from: Self.spotify, playing: false)
        XCTAssertEqual(a.receive(track("music:2"), from: Self.music, playing: false), [track("music:2")])
        XCTAssertEqual(a.current, Self.music)
    }

    /// A settings file from before the welcome window counts as welcomed; a new install doesn't.
    func testOldSettingsCountAsWelcomed() throws {
        XCTAssertFalse(RimSettings().welcomed)
        let old = try JSONDecoder().decode(RimSettings.self, from: Data(#"{"brightness": 0.5}"#.utf8))
        XCTAssertTrue(old.welcomed)
        XCTAssertEqual(old.brightness, 0.5)
        var fresh = RimSettings()
        fresh.welcomed = true
        let round = try JSONDecoder().decode(RimSettings.self, from: JSONEncoder().encode(fresh))
        XCTAssertTrue(round.welcomed)
        let unwelcomed = try JSONDecoder().decode(RimSettings.self, from: JSONEncoder().encode(RimSettings()))
        XCTAssertFalse(unwelcomed.welcomed)
    }
}
