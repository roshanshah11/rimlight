import AppKit
import QuartzCore
import RimlightCore

/// Beat detection state shared by the audio queue (writer) and the main thread (reader).
final class BeatState: @unchecked Sendable {
    private let lock = NSLock()
    private var detector: BeatDetector?
    private var train = PulseTrain()
    private var lastFeatures = AudioFeatures()
    private var lastTempo: Double?
    private var lastAudio = 0.0

    /// Called on the tap's queue. Beats are stored at the host time their onset was played on this Mac.
    func feed(_ samples: UnsafeBufferPointer<Float>, rate: Double, now: Double) {
        lock.lock(); defer { lock.unlock() }
        if detector?.sampleRate != rate { detector = BeatDetector(sampleRate: rate) }
        guard let d = detector else { return }
        d.process(samples)
        for b in d.drainBeats() { train.add(at: now - (d.time - b.time), strength: b.strength) }
        lastFeatures = d.features
        lastTempo = d.tempo
        lastAudio = now
    }

    func pulse(at t: Double, tau: Double) -> Float {
        lock.lock(); defer { lock.unlock() }
        return train.value(at: t, tau: tau)
    }

    /// Features, or silence if the tap has stopped delivering audio.
    func features(now: Double) -> AudioFeatures {
        lock.lock(); defer { lock.unlock() }
        return now - lastAudio > 1 ? AudioFeatures() : lastFeatures
    }

    var tempo: Double? { lock.lock(); defer { lock.unlock() }; return lastTempo }
}

/// Owns the overlays and decides, every frame, how bright the rim is, what color, and how hard it pulses.
final class Engine {
    private(set) var settings = RimSettings.load()
    let renderer: GlowRenderer
    let lyricsOverlay = LyricsOverlay()
    var onChange: (() -> Void)?

    private var overlays: [ScreenOverlay] = []
    private let audio = AudioTap()
    private let beats = BeatState()
    private let bridge = SpotifyBridge()
    private(set) var audioStatus = "starting"

    private(set) var track: BridgeMessage.Track?
    private var clock = PlaybackClock()
    private var grid: BeatGrid?
    private var lyrics: LyricsTimeline?

    private var fromColors = Palette.fallback.map(\.linearSIMD)
    private var toColors = Palette.fallback.map(\.linearSIMD)
    private var colorsChangedAt = -10.0

    private var fade = 0.0
    private var phase = 0.0
    private var lastUpdate = CACurrentMediaTime()
    private var lastStatus = 0.0
    private var housekeeping: Timer?
    private var rebuildPending = false

    init() throws {
        renderer = try GlowRenderer()
        if settings.colorSource == .custom { setColors(customColors(), animated: false) }
    }

    // MARK: lifecycle

    func start() {
        audio.onSamples = { [beats] buf, rate in beats.feed(buf, rate: rate, now: CACurrentMediaTime()) }
        audio.onRebuild = { [weak self] result in
            DispatchQueue.main.async { self?.audioStatus = Self.describe(result, self?.audio) }
        }
        do { try audio.start(); audioStatus = Self.describe(.success(()), audio) }
        catch { audioStatus = "unavailable: \(error)" }

        bridge.onMessage = { [weak self] m in self?.handle(m) }
        bridge.start()

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRebuild()
        }
        DistributedNotificationCenter.default().addObserver(forName: CLI.reloadNote, object: nil, queue: .main) { [weak self] _ in
            self?.apply(RimSettings.load(), save: false)
        }
        rebuildOverlays()
        housekeeping = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.housekeep() }
    }

    func stop() {
        audio.stop()
        overlays.forEach { $0.invalidate() }
        overlays = []
        try? FileManager.default.removeItem(at: RimSettings.statusURL)
    }

    private static func describe(_ r: Result<Void, Error>, _ tap: AudioTap?) -> String {
        switch r {
        case .success:
            guard let tap else { return "listening" }
            return "listening via \(tap.outputName) (\(Int(tap.outputLatency * 1000)) ms output latency)"
        case .failure(let e): return "unavailable: \(e)"
        }
    }

    // MARK: settings

    /// Apply new settings live. Changes that move or resize the strips rebuild the windows.
    func apply(_ new: RimSettings, save: Bool = true) {
        var s = new
        s.clamp()
        let old = settings
        settings = s
        if save { try? s.save() }
        if s.band != old.band || s.wrapNotch != old.wrapNotch || s.hdr != old.hdr
            || s.disabledDisplays != old.disabledDisplays || s.streamedFPS != old.streamedFPS {
            scheduleRebuild()
        }
        if s.colorSource != old.colorSource || s.customColors != old.customColors {
            if s.colorSource == .custom { setColors(customColors(), animated: true) }
            else if let t = track { loadArtwork(t) }
        }
        onChange?()
    }

    func change(_ edit: (inout RimSettings) -> Void) {
        var s = settings
        edit(&s)
        apply(s)
    }

    private func customColors() -> [RGB] {
        let c = settings.customColors.compactMap(RGB.init(hex:)).map(Palette.glowable)
        return c.count >= 3 ? Array(c.prefix(3)) : Palette.fallback
    }

    private func scheduleRebuild() {
        guard !rebuildPending else { return }
        rebuildPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.rebuildPending = false
            self?.rebuildOverlays()
        }
    }

    private func rebuildOverlays() {
        overlays.forEach { $0.invalidate() }
        overlays = NSScreen.screens
            .filter { !settings.disabledDisplays.contains($0.localizedName) }
            .map { ScreenOverlay(screen: $0, settings: settings, renderer: renderer) }
        for o in overlays {
            o.onFrame = { [weak self] o in self?.draw(o) }
            if fade > 0 { o.start() }
        }
    }

    // MARK: Spotify

    var spotifyPlaying: Bool { track != nil && !clock.paused }

    private func handle(_ m: BridgeMessage) {
        switch m {
        case .track(let t):
            let changed = t.uri != track?.uri
            var merged = t
            if !changed, merged.image == nil { merged.image = track?.image }
            track = merged
            if changed {
                grid = nil
                lyrics = nil
                clock.durationMs = t.durationMs ?? 0
            }
            if settings.colorSource == .album, changed || (t.image != nil && Artwork.isMissing(t.uri)) { loadArtwork(merged) }
            onChange?()
        case .state(let paused, let progressMs, let sentAt):
            clock = PlaybackClock(progressMs: progressMs, reportedAt: sentAt, paused: paused,
                                  durationMs: track?.durationMs ?? clock.durationMs)
            onChange?()
        case .lyrics(let uri, let synced, let lines):
            if uri == track?.uri { lyrics = synced && !lines.isEmpty ? LyricsTimeline(uri: uri, lines: lines) : nil }
        case .analysis(let uri, let tempo, let b, let conf, let bars):
            if uri == track?.uri, !b.isEmpty { grid = BeatGrid(uri: uri, tempo: tempo, beats: b, confidence: conf, bars: bars) }
        case .hello, .unavailable:
            break
        }
    }

    private func loadArtwork(_ t: BridgeMessage.Track) {
        Artwork.colors(for: t) { [weak self] colors in
            guard let self, self.track?.uri == t.uri, self.settings.colorSource == .album else { return }
            self.setColors(colors, animated: true)
        }
    }

    private func setColors(_ c: [RGB], animated: Bool) {
        let now = CACurrentMediaTime()
        fromColors = animated ? currentColors(now) : c.map(\.linearSIMD)
        toColors = c.map(\.linearSIMD)
        colorsChangedAt = animated ? now : -10
    }

    /// New cover colors blend in over about a second.
    private func currentColors(_ now: Double) -> [SIMD3<Float>] {
        let x = Float(min(1, max(0, (now - colorsChangedAt) / 1.0)))
        let k = x * x * (3 - 2 * x)
        return zip(fromColors, toColors).map { $0 + ($1 - $0) * k }
    }

    // MARK: per frame

    /// Glow while music plays; fade out over ~1.5 s when it stops, then stop drawing entirely.
    private var active: Bool {
        guard settings.enabled else { return false }
        if !settings.idleWhenPaused { return true }
        return spotifyPlaying || !beats.features(now: CACurrentMediaTime()).silent
    }

    private func update(_ now: Double) {
        let dt = min(0.1, max(0, now - lastUpdate))
        guard dt > 0.001 else { return }
        lastUpdate = now
        let target = active ? 1.0 : 0.0
        fade = target > fade ? min(target, fade + dt / 0.4) : max(target, fade - dt / 1.5)
        let energy = Double(beats.features(now: now).energy)
        phase += dt * (settings.motion == .flow ? 1 + 3 * energy : 1)
        if fade > 0 { overlays.forEach { $0.start() } }
        else if target == 0 { overlays.forEach { $0.stop() } }
    }

    /// Seconds between this Mac playing a sound and it being heard next to `o`.
    private func delay(for o: ScreenOverlay) -> Double {
        (o.streamed ? 0 : audio.outputLatency) + settings.syncOffsetMs / 1000
    }

    private func pulse(for o: ScreenOverlay, now: Double) -> (pulse: Float, energy: Float) {
        let f = beats.features(now: now)
        let d = delay(for: o)
        var p: Float
        var e = f.energy
        switch settings.motion {
        case .steady:
            p = 0; e = 0.3
        case .flow:
            p = 0.45 * f.energy + 0.35 * f.bass
        case .beat:
            if let g = grid, spotifyPlaying {
                p = g.pulse(at: clock.position(at: Date().timeIntervalSince1970 * 1000) / 1000 - d, tau: 0.06)
            } else {
                p = beats.pulse(at: now - d, tau: 0.06)
            }
        }
        p = min(1, p * Float(0.25 + settings.reactivity))
        return (p, e)
    }

    private func draw(_ o: ScreenOverlay) {
        let now = CACurrentMediaTime()
        update(now)
        guard fade > 0 else { return }
        let (p, e) = pulse(for: o, now: now)
        let frame = GlowFrame(
            geometry: o.geometry, scale: o.scale,
            thickness: Float(settings.thickness), reach: Float(settings.glow),
            brightness: Float(settings.brightness), fade: Float(fade),
            pulse: p, energy: e, time: Float(phase),
            headroom: settings.hdr && !o.streamed ? o.headroom : 1,
            colors: currentColors(now))
        o.render(frame)
    }

    // MARK: housekeeping (10 Hz, also while idle)

    private var lyricsScreen: NSScreen? {
        let screens = NSScreen.screens.filter { !settings.disabledDisplays.contains($0.localizedName) }
        if settings.lyricsDisplay != "auto" { return screens.first { $0.localizedName == settings.lyricsDisplay } }
        return screens.first { CGDisplayIsBuiltin(ScreenOverlay.displayID($0)) == 0 } ?? screens.first
    }

    private func housekeep() {
        let now = CACurrentMediaTime()
        update(now)

        // lyrics: one line and the next, only while lit
        var line: String?, next: String?
        if settings.lyrics, fade > 0.5, spotifyPlaying, let l = lyrics {
            let ms = clock.position(at: Date().timeIntervalSince1970 * 1000)
            line = l.line(at: ms)
            next = line == nil ? nil : l.next(after: ms)
        }
        lyricsOverlay.show(line: line, next: next, on: lyricsScreen, bottomInset: CGFloat(settings.band))

        if now - lastStatus >= 1 {
            lastStatus = now
            writeStatus(line: line)
        }
    }

    var beatSource: String {
        if settings.motion == .steady { return "off (steady)" }
        if settings.motion == .flow { return "audio energy (flow)" }
        if grid != nil, spotifyPlaying { return "Spotify beat map" }
        return beats.features(now: CACurrentMediaTime()).silent ? "waiting for sound" : "live audio"
    }

    var tempo: Double? { grid?.tempo ?? beats.tempo }

    var songLine: String? {
        guard let t = track, let name = t.name else { return nil }
        return [name, t.artist].compactMap { $0 }.joined(separator: " - ") + (clock.paused ? " (paused)" : "")
    }

    private func writeStatus(line: String?) {
        let st = Status(updatedAt: Date().timeIntervalSince1970, enabled: settings.enabled, lit: fade > 0,
                        song: songLine, beatSource: beatSource, tempo: tempo, audio: audioStatus,
                        screens: overlays.filter(\.running).map { $0.name + ($0.streamed ? " (streamed)" : "") },
                        lyrics: line)
        guard let data = try? JSONEncoder().encode(st) else { return }
        try? FileManager.default.createDirectory(at: RimSettings.directory, withIntermediateDirectories: true)
        try? data.write(to: RimSettings.statusURL, options: .atomic)
    }
}
