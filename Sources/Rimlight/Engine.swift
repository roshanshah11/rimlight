import AppKit
import CoreAudio
import QuartzCore
import RimlightCore

/// Beat detection shared by the audio queue (writer) and the main thread (reader). Every time is "sound time":
/// the host time (CACurrentMediaTime seconds) the sample was played by the app the tap listens to.
final class BeatState: @unchecked Sendable {
    private let lock = NSLock()
    private var detector: BeatDetector?
    private var onsets: [(time: Double, strength: Float)] = []
    private var lastFeatures = AudioFeatures()
    private var lastTempo: Double?
    private var lastAudio = 0.0

    /// Called on the tap's queue with the host time of the buffer's first sample.
    func feed(_ samples: UnsafeBufferPointer<Float>, rate: Double, start: Double) {
        lock.lock(); defer { lock.unlock() }
        if detector?.sampleRate != rate { detector = BeatDetector(sampleRate: rate) }
        guard let d = detector else { return }
        let t0 = d.time
        d.process(samples)
        for b in d.drainBeats() { onsets.append((start + (b.time - t0), b.strength)) }
        if onsets.count > 64 { onsets.removeFirst(onsets.count - 64) }
        lastFeatures = d.features
        lastTempo = d.tempo
        lastAudio = start + Double(samples.count) / rate
    }

    func drainOnsets() -> [(time: Double, strength: Float)] {
        lock.lock(); defer { lock.unlock() }
        defer { onsets.removeAll(keepingCapacity: true) }
        return onsets
    }

    /// Features, or silence if the tap has stopped delivering audio.
    func features(now: Double) -> AudioFeatures {
        lock.lock(); defer { lock.unlock() }
        return now - lastAudio > 1 ? AudioFeatures() : lastFeatures
    }

    var tempo: Double? { lock.lock(); defer { lock.unlock() }; return lastTempo }

    /// A new song: its loudness is measured against itself, not the last one.
    func newSong() { lock.lock(); detector?.newSong(); lock.unlock() }
}

/// Owns the overlays and runs the light show. Timing, end to end:
/// - The tap timestamps every sample with when its app played it ("sound time").
/// - Live, the BeatClock turns detected kicks into predicted beats on that clock (no detection delay).
/// - With Spotify's analysis, the beat map is placed on the same clock: Spotify's reported position, corrected by
///   the GridCalibrator's measured offset against the kicks the tap actually hears; the SongPlan plans the looks.
/// - Each frame is drawn for the moment it reaches the screen (the display link's target, plus half a frame),
///   minus the time from playing to hearing: the iMac stream's sound trails its picture by ~50 ms
///   (imac-stream-receiver.m: picture shown on arrival, sound from a 60 ms cushion); local speakers add their
///   output latency.
final class Engine {
    /// How much later the iMac's speakers sound than its picture shows (see above; `rimlight offset` trims it).
    static let streamedAVDelay = 0.050

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
    private var spotifyKnown = false      // a play state arrived and Spotify is still running
    private var grid: BeatGrid?
    private var plan: SongPlan?
    private var lyrics: LyricsTimeline?

    private let director = ShowDirector(palette: Palette.fallback)
    private let beatClock = BeatClock()
    private let gridSync: GridSync
    private var calibrator: GridCalibrator { gridSync.calibrator }
    private var lastOnset = -10.0
    private var toRGB = Palette.fallback
    private var light = LightState()
    private var lightFor = 0.0            // the show time of `light`
    private var lastShowTime = 0.0

    private var fade = 0.0
    private var lowMemory = false, memoryCritical = false
    private var memoryPressure: DispatchSourceMemoryPressure?
    /// `rimlight debug-lit <s>`: glow with a fixed look for a few seconds, no music needed (memory and CPU checks).
    private var litUntil = 0.0
    private var analysis: SongAnalysis?
    private var hooks: [Range<Double>] = []
    private let launchedAt = CACurrentMediaTime()
    private var lastUpdate = CACurrentMediaTime()
    private var lastStatus = 0.0
    private var lastCalibrationSave = 0.0
    private var housekeeping: Timer?
    private var rebuildPending = false

    private static var calibrationURL: URL { RimSettings.directory.appendingPathComponent("calibration.json") }

    init() throws {
        renderer = try GlowRenderer()
        let saved = (try? Data(contentsOf: Self.calibrationURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        gridSync = GridSync(calibrator: GridCalibrator(offset: (saved?["offset"] as? NSNumber)?.doubleValue ?? 0))
        director.allowFlashes = settings.flashes
        director.setStyle(.hiphop)                       // most of what he plays; the judge corrects it per song
        director.forcedStyle = settings.motion == .flow ? .ambient : nil
        if settings.colorSource == .custom { setColors(customColors()) }
    }

    // MARK: lifecycle

    func start() {
        if FileManager.default.fileExists(atPath: "/tmp/rimlight-onset-dump") {
            // debug: each onset against Spotify's map, for checking the map correction on real songs
            gridSync.onObserve = { [weak self] t, s, d, period in
                guard let self else { return }
                let line = String(format: "{\"uri\":\"%@\",\"t\":%.4f,\"s\":%.3f,\"d\":%.4f,\"period\":%.4f,\"offset\":%.4f,\"settled\":%@}\n",
                                  self.track?.uri ?? "", t, s, d, period, self.calibrator.offset, self.calibrator.settled ? "true" : "false")
                let url = URL(fileURLWithPath: "/tmp/rimlight-onsets.jsonl")
                if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? Data(line.utf8).write(to: url) }
            }
        }
        audio.onSamples = { [beats, tapRecorder] buf, rate, start in
            beats.feed(buf, rate: rate, start: start)
            tapRecorder.feed(buf, rate: rate, start: start)
        }
        audio.onRebuild = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.audioStatus = Self.describe(result, self.audio)
                self.lastOutputCheck = 0
                self.refreshOutput(CACurrentMediaTime())
                if self.output.uid != self.seededFor { self.relearnSync() }
            }
        }
        audioStatus = "nothing playing"

        bridge.onMessage = { [weak self] m in self?.handle(m) }
        bridge.start()

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRebuild()
        }
        DistributedNotificationCenter.default().addObserver(forName: CLI.reloadNote, object: nil, queue: .main) { [weak self] _ in
            self?.apply(RimSettings.load(), save: false)
        }
        DistributedNotificationCenter.default().addObserver(forName: CLI.calibrateNote, object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            switch n.object as? String ?? "start" {
            case "earlier": self.calibration?.earlier()
            case "later": self.calibration?.later()
            case "save": self.calibration?.save()
            case "stop": self.calibration?.cancel()
            case "manual": self.startCalibration()
            case "selfcheck": self.chirpSelfCheck()
            default: self.startAutoCalibration()
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: CLI.litNote, object: nil, queue: .main) { [weak self] n in
            let seconds = Double(n.object as? String ?? "") ?? 5
            self?.litUntil = CACurrentMediaTime() + min(60, seconds)
        }
        // under memory pressure the strips are rebuilt at half a pixel per point; when it's critical, the glow
        // stops drawing until it eases (a light show isn't worth the Mac swapping)
        let mp = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        mp.setEventHandler { [weak self, weak mp] in
            guard let self, let e = mp?.data else { return }
            let low = !e.contains(.normal)
            self.memoryCritical = e.contains(.critical)
            if low != self.lowMemory { self.lowMemory = low; self.scheduleRebuild() }
        }
        mp.resume()
        memoryPressure = mp
        rebuildOverlays()
        housekeeping = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.housekeep() }
    }

    func stop() {
        audio.stop()
        overlays.forEach { $0.invalidate() }
        overlays = []
        saveCalibration()
        try? FileManager.default.removeItem(at: RimSettings.statusURL)
    }

    /// The output the map was last relearned for: a new one starts the song's correction over.
    private var seededFor = ""

    private func saveCalibration() {
        guard calibrator.confident, calibrator.settled else { return }
        try? FileManager.default.createDirectory(at: RimSettings.directory, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: ["offset": calibrator.baseline])
            .write(to: Self.calibrationURL, options: .atomic)
    }

    /// Start learning again (a new song, or a new output) from the songs' average. The map sits the same against
    /// the tap on every output (0 to +21 ms on the Beats, +28 on the speakers): the -124 and -195 ms once read as the
    /// Beats' own were the map settling half a beat wrong (GridCalibrator).
    private func relearnSync() {
        seededFor = output.uid
        calibrator.newTrack()
    }
    private var trackStartedAt = 0.0

    private static func describe(_ r: Result<Void, Error>, _ tap: AudioTap?) -> String {
        switch r {
        case .success:
            guard let tap, tap.running else { return "nothing playing" }
            return "listening to \(tap.tappedNames.joined(separator: ", ")) on \(tap.outputName) "
                + "(\(Int(tap.outputLatency * 1000)) ms output latency)"
        case .failure(let e): return "unavailable: \(e)"
        }
    }

    private var lastPlayersCheck = 0.0
    private var playersGoneAt: Double?

    /// Listen to whoever is playing; stop listening 2 s after everyone stops (and while Spotify is paused, since
    /// its play state decides then anyway).
    private func updateTap(_ now: Double) {
        guard now - lastPlayersCheck >= 0.5 else { return }
        lastPlayersCheck = now
        var players = settings.enabled ? AudioTap.players() : []
        if spotifyKnown, !spotifyPlaying { players = [] }
        if players.isEmpty {
            guard audio.running else { playersGoneAt = nil; return }
            if playersGoneAt == nil { playersGoneAt = now }
            if now - (playersGoneAt ?? now) >= 2 {
                audio.stop()
                playersGoneAt = nil
                audioStatus = Self.describe(.success(()), audio)
            }
            return
        }
        playersGoneAt = nil
        let ids = players.map(\.id)
        guard ids != audio.tapped else { return }
        do { try audio.start(processes: players); audioStatus = Self.describe(.success(()), audio) }
        catch { audioStatus = "unavailable: \(error)" }
    }

    // MARK: settings

    /// Apply new settings live. Changes that move or resize the strips rebuild the windows.
    func apply(_ new: RimSettings, save: Bool = true) {
        var s = new
        s.clamp()
        let old = settings
        settings = s
        if save { try? s.save() }
        if s.band != old.band || s.wrapNotch != old.wrapNotch || s.hdr != old.hdr || s.iMacOnly != old.iMacOnly || s.renderScale != old.renderScale
            || s.disabledDisplays != old.disabledDisplays || s.streamedFPS != old.streamedFPS {
            scheduleRebuild()
        }
        director.allowFlashes = s.flashes
        director.forcedStyle = s.motion == .flow ? .ambient : nil
        if s.colorSource != old.colorSource || s.customColors != old.customColors {
            if s.colorSource == .custom { setColors(customColors()) }
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
        return c.isEmpty ? Palette.fallback : c
    }

    private func scheduleRebuild() {
        guard !rebuildPending else { return }
        rebuildPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.rebuildPending = false
            self?.rebuildOverlays()
        }
    }

    /// Screens that glow: all but the disabled ones, or only the iMac while its stream is up.
    private var litScreens: [NSScreen] {
        let screens = NSScreen.screens.filter { !settings.disabledDisplays.contains($0.localizedName) }
        let iMac = screens.filter(ScreenOverlay.isStreamed)
        return settings.iMacOnly && !iMac.isEmpty ? iMac : screens
    }

    private func rebuildOverlays() {
        overlays.forEach { $0.invalidate() }
        overlays = litScreens.map { ScreenOverlay(screen: $0, settings: settings, renderer: renderer, lowMemory: lowMemory) }
        for o in overlays {
            o.onFrame = { [weak self] o, at, period in self?.draw(o, at: at, period: period) }
            if fade > 0 { o.start() }
        }
    }

    // MARK: Spotify

    var spotifyPlaying: Bool { track != nil && !clock.paused }

    private func handle(_ m: BridgeMessage) {
        switch m {
        case .track(let t):
            let changed = t.uri != track?.uri
            if changed { logSong() }   // the song that just ended, with its own evidence
            var merged = t
            if !changed, merged.image == nil { merged.image = track?.image }
            track = merged
            if changed {
                analysis = nil
                grid = nil
                gridSync.setGrid(nil)
                plan = nil
                lyrics = nil
                clock.durationMs = t.durationMs ?? 0
                director.reset()
                beatClock.reset()
                saveCalibration()
                relearnSync()   // each song's beat map sits differently on its kicks
                trackStartedAt = CACurrentMediaTime()
                beats.newSong()
            }
            if settings.colorSource == .album, changed || (t.image != nil && Artwork.isMissing(t.uri)) { loadArtwork(merged) }
            onChange?()
        case .state(let paused, let progressMs, let sentAt):
            spotifyKnown = true
            clock.durationMs = track?.durationMs ?? clock.durationMs
            clock.update(progressMs: progressMs, reportedAt: sentAt, paused: paused)
            onChange?()
        case .lyrics(let uri, let synced, let lines):
            guard uri == track?.uri else { return }
            lyrics = synced && !lines.isEmpty ? LyricsTimeline(uri: uri, lines: lines) : nil
            rebuildPlan()   // the hook comes from the lyrics
        case .analysis(let uri, let tempo, let b, let conf, let bars, let sections, let loudness):
            guard uri == track?.uri, !b.isEmpty else { return }
            grid = BeatGrid(uri: uri, tempo: tempo, beats: b, confidence: conf, bars: bars)
            gridSync.setGrid(grid)
            if loudness.count == b.count, !sections.isEmpty {
                analysis = SongAnalysis(tempo: tempo, beats: b, bars: bars, sections: sections, beatLoudness: loudness)
            }
            rebuildPlan()
        case .hello, .unavailable:
            break
        }
    }

    /// The plan from Spotify's analysis, with the hook from the synced lyrics when there are any.
    private func rebuildPlan() {
        hooks = lyrics.map { HookFinder.hooks($0.lines) } ?? []
        plan = analysis.flatMap { SongPlan.make($0, hooks: hooks) }
        director.setPlan(plan)
    }

    /// One line per song in songs.jsonl: the style it got and why, to check the judge against his real library.
    private func logSong() {
        guard let t = track, director.judge.evidence.beats > 0 else { return }
        struct Entry: Encodable {
            var at: String, uri: String, name: String?, artist: String?, tempo: Double?, style: String?
            var evidence: StyleJudge.Evidence, hooks: Int, drops: Int, analysis: Bool, lyrics: Bool, mapSettled: Bool
        }
        let e = Entry(at: ISO8601DateFormatter().string(from: Date()), uri: t.uri, name: t.name, artist: t.artist,
                      tempo: grid?.tempo, style: director.judge.verdict?.rawValue, evidence: director.judge.evidence,
                      hooks: plan?.hooks.count ?? 0, drops: plan?.drops.count ?? 0, analysis: grid != nil,
                      lyrics: lyrics != nil, mapSettled: calibrator.settled)
        guard var line = try? JSONEncoder().encode(e) else { return }
        line.append(0x0A)
        let url = RimSettings.directory.appendingPathComponent("songs.jsonl")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1 << 20,
           let old = try? Data(contentsOf: url) {
            try? old.suffix(old.count / 2).write(to: url)   // keep the newer half
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    private func loadArtwork(_ t: BridgeMessage.Track) {
        Artwork.colors(for: t) { [weak self] colors in
            guard let self, self.track?.uri == t.uri, self.settings.colorSource == .album else { return }
            self.setColors(colors)
        }
    }

    private func setColors(_ c: [RGB]) {
        toRGB = c
        director.setPalette(c, at: CACurrentMediaTime())
    }

    // MARK: time

    /// Both clocks read together, for GridSync.
    private var clocksNow: GridSync.Now { .init(host: CACurrentMediaTime(), epochMs: Date().timeIntervalSince1970 * 1000) }

    /// From playing a sound to hearing it next to `o`.
    private func delay(for o: ScreenOverlay) -> Double {
        let streaming = overlays.contains(where: \.streamed)
        if o.streamed || streaming { return streamDelay + settings.syncOffsetMs / 1000 }
        // the output's reported latency, plus what calibrating it found (Bluetooth headphones report a round 160 ms)
        let base = audio.running ? audio.outputLatency : output.latency
        let measured = calibration?.offsetMs ?? settings.deviceOffsets[output.uid] ?? 0
        return base + (measured + settings.syncOffsetMs) / 1000
    }

    // MARK: calibration

    /// The current output, refreshed once a second (Core Audio calls are too slow for every frame).
    private var output = (uid: "", name: "", latency: 0.0)
    private var lastOutputCheck = 0.0
    private(set) var calibration: Calibration?

    /// The iMac stream's measured hold (imac-stream writes it once a second from both ends' delays), eased so a
    /// change of the iMac's sound cushion slides in over a few seconds; the fixed guess when there's no measurement.
    private var streamDelay = Engine.streamedAVDelay
    private var streamMeasured = false
    private static let streamSyncURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/imac-display/av-sync.json")

    private func refreshStream() {
        guard let target = StreamSync.hold(from: try? Data(contentsOf: Self.streamSyncURL)) else {
            if streamMeasured { streamMeasured = false; streamDelay = Self.streamedAVDelay }
            return
        }
        streamDelay = streamMeasured ? streamDelay + (target - streamDelay) * 0.3 : target
        streamMeasured = true
    }

    private func refreshOutput(_ now: Double) {
        guard now - lastOutputCheck >= 1 else { return }
        lastOutputCheck = now
        if overlays.contains(where: \.streamed) { refreshStream() }
        guard let dev = try? AudioTap.defaultOutput(),
              let uid = try? AudioTap.stringProperty(dev, kAudioDevicePropertyDeviceUID) else { return }
        output = (uid, (try? AudioTap.stringProperty(dev, kAudioObjectPropertyName)) ?? uid, AudioTap.latency(of: dev))
    }

    private var auto: AutoCalibration?
    /// The tapped song during a calibration, to line up with the mic.
    let tapRecorder = TapRecorder()

    /// What the light waits for the current output right now, ms (before a new calibration is saved).
    var lightDelayMs: Double { overlays.first.map { delay(for: $0) * 1000 } ?? 0 }

    /// Every calibration run, kept for checking the method later: calibration-log.jsonl.
    func logCalibration(_ o: ChirpRun.Outcome) {
        var d: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "output": o.outputName, "uid": o.outputUID,
                                "reportedMs": o.reported * 1000, "bufferMs": o.buffer * 1000, "waitedMs": lightDelayMs,
                                "chirps": ["heard": o.result.heard, "latencyMs": o.result.latency * 1000, "spreadMs": o.result.spread * 1000],
                                "ok": o.ok, "offsetMs": o.offsetMs, "debug": o.debug]
        if let m = o.music {
            d["song"] = ["delayMs": m.delay * 1000, "clarity": m.clarity, "halvesMs": m.halves.map { $0 * 1000 }, "ok": m.ok]
        }
        guard var line = try? JSONSerialization.data(withJSONObject: d) else { return }
        line.append(0x0a)
        let url = RimSettings.directory.appendingPathComponent("calibration-log.jsonl")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }

    /// Measure the current output with chirps and the MacBook's mic (AutoCalibration); "Adjust by hand" in its panel
    /// opens the click-and-flash check (startCalibration).
    func startAutoCalibration() {
        guard auto == nil, calibration == nil else { return }
        if overlays.contains(where: \.streamed) { return startCalibration() }   // says the stream times itself
        lastOutputCheck = 0
        refreshOutput(CACurrentMediaTime())
        let a = AutoCalibration(engine: self)
        a.onClose = { [weak self] in self?.auto = nil; self?.onChange?() }
        a.onManual = { [weak self] in self?.auto = nil; self?.startCalibration() }
        auto = a
        let bluetooth = (try? AudioTap.defaultOutput()).map(AudioTap.isBluetooth) ?? false
        a.show(outputName: output.name, bluetooth: bluetooth, songPlaying: spotifyPlaying && !beats.features(now: CACurrentMediaTime()).silent)
    }

    func saveMeasuredLatency(uid: String, offsetMs: Double) {
        var s = settings
        s.deviceOffsets[uid] = offsetMs
        apply(s)
    }

    /// `rimlight calibrate selfcheck`: chirps through the MacBook's own speakers, timed by its mic, nothing saved;
    /// the result goes to chirp-selfcheck.json. Checks the method against an output whose latency is known.
    func chirpSelfCheck() {
        AutoCalibration.withMic { granted in
            let url = RimSettings.directory.appendingPathComponent("chirp-selfcheck.json")
            guard granted else { try? Data(#"{"error":"no microphone permission"}"#.utf8).write(to: url); return }
            let r = ChirpRun()
            r.run(output: ChirpRun.builtInSpeakers()) { o in
                _ = r
                let d: [String: Any] = o.map { ["heard": $0.result.heard, "latencyMs": $0.result.latency * 1000, "spreadMs": $0.result.spread * 1000,
                                               "macOSSaysMs": $0.reportedSound * 1000, "offsetMs": $0.offsetMs, "output": $0.outputName, "timingsMs": $0.result.timings.map { $0 * 1000 },
                                               "debug": $0.debug] }
                    ?? ["error": "could not open the mic or speakers"]
                try? JSONSerialization.data(withJSONObject: d).write(to: url)
            }
        }
    }

    /// Clicks in the current output and a flash on the rim; the arrow keys line them up (Calibration).
    func startCalibration() {
        guard calibration == nil else { return }
        if overlays.contains(where: \.streamed) {
            let a = NSAlert()
            a.messageText = "The iMac stream times itself"
            a.informativeText = "While the iMac stream is up, the light follows the stream's own delay. Calibrate with the sound coming out of this Mac (speakers or headphones)."
            a.runModal()
            return
        }
        lastOutputCheck = 0
        refreshOutput(CACurrentMediaTime())
        let c = Calibration(outputUID: output.uid, outputName: output.name,
                            offsetMs: settings.deviceOffsets[output.uid] ?? 0, latency: output.latency)
        c.onFinish = { [weak self] save in
            guard let self, let c = self.calibration else { return }
            self.calibration = nil
            if save {
                var s = self.settings
                s.deviceOffsets[c.outputUID] = c.offsetMs
                self.apply(s)
            }
            self.onChange?()
        }
        calibration = c
        c.start()
        onChange?()
    }

    // MARK: per frame

    /// Glow while music plays; fade out over ~1.5 s when it stops, then stop drawing entirely. While Spotify runs
    /// and has reported its state, its play state decides (a lecture video doesn't light the rim); otherwise any
    /// sound does.
    private var active: Bool {
        if calibration != nil || CACurrentMediaTime() < litUntil { return true }
        guard settings.enabled, !memoryCritical else { return false }
        if !settings.idleWhenPaused { return true }
        if spotifyKnown { return spotifyPlaying }
        // just launched with Spotify open: give the bridge a few seconds to say whether it's playing, so another
        // app's sound doesn't flash the rim first
        let now = CACurrentMediaTime()
        if now - launchedAt < 6, !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty {
            return false
        }
        return !beats.features(now: now).silent
    }

    private func update(_ now: Double) {
        let dt = min(0.1, max(0, now - lastUpdate))
        guard dt > 0.001 else { return }
        lastUpdate = now
        let target = active ? 1.0 : 0.0
        fade = target > fade ? min(target, fade + dt / 0.4) : max(target, fade - dt / 1.5)
        if fade > 0 { overlays.forEach { $0.start() } }
        else if target == 0 { overlays.forEach { $0.stop() } }
    }

    /// Hear, count and decide everything up to show time `t`.
    private func advanceShow(to t: Double) {
        let now = CACurrentMediaTime()
        let f = beats.features(now: now)
        let haveGrid = grid != nil && spotifyPlaying
        // the map's beats light the show once this song's offset is measured (or while it's still early); a song
        // whose offset hasn't settled after 15 s (the guess was more than a quarter beat out) is lit from the live
        // clock instead while the map keeps learning
        let usingGrid = haveGrid && (calibrator.settled || now - trackStartedAt < 15 || !beatClock.locked)
        director.onGrid = usingGrid ? calibrator.settled : beatClock.locked

        let clocks = clocksNow
        for o in beats.drainOnsets() {
            lastOnset = o.time
            beatClock.onset(at: o.time, strength: o.strength)
            director.heard(onset: o.time, strength: o.strength)
            if haveGrid {
                gridSync.observe(onset: o.time, strength: o.strength, clock: clock, now: clocks)   // calibrate the map
            }
            // (no light on raw onset reports while the live clock is unlocked: an unlocked rap song lit that way
            // looked random, 2026-10-25; the look holds steady until the clock locks)
        }
        beatClock.setTempo(beats.tempo)

        var trackPos: Double?
        if settings.motion == .beat {
            if usingGrid {
                trackPos = gridSync.trackTime(forSound: t, clock: clock, now: clocks)
                for b in gridSync.beats(through: t, clock: clock, now: clocks) {
                    director.beat(at: b.sound, strength: b.strength, downbeat: b.downbeat, trackTime: b.track)
                }
            } else {
                for bt in beatClock.beats(after: lastShowTime, through: t, lastOnset: lastOnset) {
                    director.beat(at: bt, strength: 0.8)
                }
            }
        }
        lastShowTime = t

        let tempo: Double? = usingGrid ? grid?.tempo : (beatClock.locked ? beatClock.period.map { 60 / $0 } : beats.tempo)
        let input = MusicInput(energy: settings.motion == .steady ? 0.5 : f.loudness, level: f.level, bass: f.lowLoud,
                               treble: f.highLoud, tempo: tempo, trackTime: plan != nil ? trackPos : nil, tilt: f.tilt,
                               bassShare: f.bassShare, crest: f.crest, lowLevel: f.lowLevel)
        var l = director.frame(at: t, input)
        let k = Float(0.25 + settings.reactivity)
        l.pulse = min(1, l.pulse * k)
        l.flash = min(1, l.flash * k)
        if settings.motion == .steady { l.pulse = 0; l.flash = 0 }
        light = l
        lightFor = t
    }

    /// One frame for `o`, reaching the screen at `at` and staying for `period`.
    private func draw(_ o: ScreenOverlay, at: Double, period: Double) {
        update(CACurrentMediaTime())
        guard fade > 0 else { return }
        // the frame is seen from when it really lands (a refresh or so after the link's target) for one refresh
        let t = at + (o.presentLag.value ?? 0) + period / 2 - delay(for: o)
        if let c = calibration {
            light = c.light(at: t)
            lightFor = t
        } else if CACurrentMediaTime() < litUntil {
            var l = LightState()
            l.section = .groove; l.master = 0.85; l.bloom = 0.8; l.fixtures = 3; l.fixtureLevel = 0.85; l.washLevel = 0.12
            l.colorA = SIMD3(0.45, 0.25, 1); l.colorB = SIMD3(0.1, 0.55, 1); l.wash = l.colorA
            light = l
            lightFor = t
        } else if abs(t - lightFor) > 0.002 { advanceShow(to: t) }
        let frame = GlowFrame(
            geometry: o.geometry, scale: o.scale,
            edge: Float(settings.thickness), reach: Float(settings.glow),
            brightness: Float(settings.brightness), fade: Float(fade),
            headroom: settings.hdr && !o.streamed ? o.headroom : 1,
            light: light, target: at)
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
        refreshOutput(now)
        update(now)
        updateTap(now)

        var line: String?, next: String?
        if settings.lyrics, fade > 0.5, spotifyPlaying, let l = lyrics {
            let ms = clock.position(at: Date().timeIntervalSince1970 * 1000)
            line = l.line(at: ms)
            next = line == nil ? nil : l.next(after: ms)
        }
        lyricsOverlay.show(line: line, next: next, on: lyricsScreen, bottomInset: CGFloat(settings.band))

        if now - lastStatus >= 1 {
            lastStatus = now
            if spotifyKnown, NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty {
                spotifyKnown = false
                clock.paused = true
            }
            writeStatus(line: line)
        }
        if now - lastCalibrationSave > 30 {
            lastCalibrationSave = now
            saveCalibration()
        }
    }

    var beatSource: String {
        if settings.motion == .steady { return "off (steady)" }
        if settings.motion == .flow { return "audio energy (flow)" }
        if grid != nil, spotifyPlaying {
            return plan != nil ? "Spotify beat map + song plan" : "Spotify beat map"
        }
        if beats.features(now: CACurrentMediaTime()).silent { return "waiting for sound" }
        return beatClock.locked ? "live audio, locked" : "live audio, finding the beat"
    }

    var tempo: Double? {
        if let g = grid, spotifyPlaying { return g.tempo }
        if beats.features(now: CACurrentMediaTime()).silent { return nil }
        return beatClock.locked ? beatClock.period.map { 60 / $0 } : beats.tempo
    }

    var timingLine: String {
        let cal = calibrator.confident ? String(format: "%+.0f ms (spread %.0f ms)", calibrator.offset * 1000, calibrator.spread * 1000)
            : "learning"
        let d = overlays.first.map { String(format: "%.0f ms", delay(for: $0) * 1000) } ?? "-"
        let live = beatClock.locked ? beatClock.typicalError.map { String(format: ", live clock locked (kicks within %.0f ms)", $0 * 1000) }
            ?? ", live clock locked" : ""
        let streamed = overlays.contains(where: \.streamed)
        let measured = streamed ? (streamMeasured ? " (iMac stream, measured)" : " (iMac stream, assumed)")
            : settings.deviceOffsets[output.uid].map { String(format: " (%@ calibrated %+.0f ms)", output.name, $0) } ?? ""
        let screen = overlays.first?.presentLag.spread.map {
            String(format: ", frames land %.1f ms after target (%.1f to %.1f)", $0.median * 1000, $0.p10 * 1000, $0.p90 * 1000)
        } ?? ""
        return "Spotify map correction \(cal), light delay \(d)\(measured)\(live)\(screen)"
    }

    /// The part of the song the show is in (the menu's look line).
    var section: Section { light.section }

    /// This song's style.
    var style: ShowStyle { director.style }

    var lookLine: String {
        if settings.motion == .steady { return "steady" }
        let st = director.style
        let judged = settings.motion == .flow ? "ambiance (chosen in the menu)" : (director.judge.verdict == nil ? "judging the song" : "\(st.label) show")
        var line = "\(st.name(light.section)), \(judged)"
        if let p = plan {
            line += ", planned from Spotify's analysis"
            if !p.hooks.isEmpty { line += ", hook from the lyrics (\(p.hooks.count)x)" }
            else if st == .club { line += " (\(p.drops.count) drops)" }
        }
        return line
    }

    var songLine: String? {
        guard let t = track, let name = t.name else { return nil }
        return [name, t.artist].compactMap { $0 }.joined(separator: " - ") + (clock.paused ? " (paused)" : "")
    }

    private func writeStatus(line: String?) {
        let look = lookLine
        let st = Status(updatedAt: Date().timeIntervalSince1970, enabled: settings.enabled, lit: fade > 0,
                        song: songLine, beatSource: beatSource, tempo: tempo, audio: audioStatus,
                        screens: overlays.filter(\.running).map { $0.name + ($0.streamed ? " (streamed)" : "") },
                        lyrics: line, colors: toRGB.map(\.hex), uri: track?.uri, show: look, timing: timingLine)
        guard let data = try? JSONEncoder().encode(st) else { return }
        try? FileManager.default.createDirectory(at: RimSettings.directory, withIntermediateDirectories: true)
        try? data.write(to: RimSettings.statusURL, options: .atomic)
    }
}
