import Foundation

/// The kind of show a song gets. DJs light a rap set differently from a house set, and a slow song is better as
/// ambiance than as a light show.
public enum ShowStyle: String, Sendable, CaseIterable {
    case club      // four on the floor: builds, a blackout, the drop's white hit, chases
    case hiphop    // rap and most pop: verse and hook, hits on the 808 and the clap, the beat cutting out and back
    case ambient   // slow or soft: a breathing wash in the cover's colors, no hits

    /// The style's name in the menu.
    public var label: String {
        switch self { case .club: return "club"; case .hiphop: return "rap"; case .ambient: return "ambiance" }
    }

    /// What the menu and `rimlight status` call each section in this style.
    public func name(_ s: Section) -> String {
        switch (self, s) {
        case (.ambient, _): return "Ambiance"
        case (.hiphop, .groove): return "Verse"
        case (.hiphop, .build): return "Pre-hook"
        case (.hiphop, .drop): return "Hook"
        case (.club, .groove): return "Groove"
        case (.club, .build): return "Build"
        case (.club, .drop): return "Drop"
        case (_, .quiet): return "Quiet"
        }
    }
}

/// Picks a song's style from its first bars of music (not its intro): how slow it feels, how much of the mix the
/// kick and bass carry, how hard and how often it hits, and whether a kick lands on every beat.
///
/// Thresholds come from the synthetic genres only (SyntheticSong, SyntheticTrap, SyntheticBallad, 2026-10-25: bass
/// share +8.0, +7.7 and +4.5 dB; a kick on 92%, 25% and 10% of the beats once the music is in). Every verdict is
/// logged with its evidence (Engine's songs.jsonl) so they can be checked against a real library.
public struct StyleJudge: Sendable {
    public struct Evidence: Sendable, Codable, Equatable {
        public var beats = 0              // beats of music heard (outside quiet parts)
        public var feltBPM: Double = 0
        public var bassShare: Float = 0   // median, dB
        public var strongPerSecond = 0.0
        public var meanStrength: Float = 0
        public var kickOnBeat = 0.0       // share of beats with a strong onset on them
        public var crest: Float = 0       // median, dB
    }

    public private(set) var evidence = Evidence()
    public private(set) var verdict: ShowStyle?
    /// Each look at the song: what it heard and what it said.
    public private(set) var history: [(evidence: Evidence, style: ShowStyle)] = []
    private var shares: [Float] = []
    private var crests: [Float] = []
    private var lookedEarly = false
    private var onsets: [(t: Double, s: Float)] = []
    private var beatTimes: [Double] = []
    private var firstBeat: Double?
    private var lastBeatTime = 0.0

    public init() {}

    /// A strong-enough onset the tap heard.
    public mutating func onset(at t: Double, strength: Float) {
        onsets.append((t, strength))
        if onsets.count > 400 { onsets.removeFirst(onsets.count - 400) }
    }

    /// A counted beat of music (not in a quiet part), with the felt tempo and the mix's bass share right now.
    public mutating func beat(at t: Double, feltBPM: Double, bassShare: Float, crest: Float = 0) {
        crests.append(crest)
        if crests.count > 128 { crests.removeFirst(crests.count - 128) }
        if firstBeat == nil { firstBeat = t }
        lastBeatTime = t
        beatTimes.append(t)
        if beatTimes.count > 128 { beatTimes.removeFirst(beatTimes.count - 128) }
        shares.append(bassShare)
        if shares.count > 128 { shares.removeFirst(shares.count - 128) }
        evidence.beats += 1
        evidence.feltBPM = feltBPM
        // decide after 16 beats of music, then look again every 16 beats up to 64, at the last 24 beats (a slow
        // intro can turn into a rap song)
        // (a slow song gets its first look after 10 seconds instead of 16 beats)
        let slowFirst = verdict == nil && evidence.beats >= 8 && t - (firstBeat ?? t) >= 10 && !lookedEarly
        if slowFirst { lookedEarly = true }
        if slowFirst || (evidence.beats >= 16 && evidence.beats <= 64 && evidence.beats % 16 == 0) { judge() }
    }

    private mutating func judge() {
        let recent = Array(beatTimes.suffix(24))
        guard let first = recent.first, lastBeatTime > first else { return }
        let window = onsets.filter { $0.t >= first - 0.05 && $0.t <= lastBeatTime + 0.05 }
        let strong = window.filter { $0.s >= 0.6 }
        let span = lastBeatTime - first + 60 / max(evidence.feltBPM, 1)
        evidence.strongPerSecond = Double(strong.count) / span
        evidence.meanStrength = window.isEmpty ? 0 : window.map(\.s).reduce(0, +) / Float(window.count)
        let share = shares.suffix(24).sorted()
        evidence.bassShare = share[share.count / 2]
        let cr = crests.suffix(24).sorted()
        evidence.crest = cr[cr.count / 2]
        // a kick on the beat: any clear onset on it (kicks next to a clap read weaker than the clap)
        let hits = window.filter { $0.s >= 0.45 }
        let onBeat = recent.filter { b in hits.contains { abs($0.t - b) < 0.07 } }.count
        evidence.kickOnBeat = Double(onBeat) / Double(max(1, recent.count))
        let next = Self.style(evidence, from: verdict)
        history.append((evidence, next))
        // a first look that can't tell a club track from rap (kicks on some beats at house tempo, often the beat
        // clock still settling) waits for the next one
        let unsure = verdict == nil && evidence.beats < 32 && evidence.kickOnBeat >= 0.4 && evidence.kickOnBeat < 0.75
            && evidence.feltBPM >= 110 && evidence.feltBPM <= 140
        if !unsure { verdict = next }
    }

    /// Slow songs whose bass doesn't dominate are ambiance; a kick on every beat at house tempo is club; the rest
    /// (rap, pop, R&B with 808s) is hip-hop. A later look only moves up (ambient, hip-hop, club): a build with the
    /// kick cut doesn't make a club track rap, a verse without drums doesn't make a rap song ambiance, and leaving
    /// ambiance takes the bass arriving (a live tempo guess drifting on a ballad doesn't).
    public static func style(_ e: Evidence, from current: ShowStyle? = nil) -> ShowStyle {
        let club = e.kickOnBeat >= 0.75 && e.feltBPM >= 110 && e.feltBPM <= 140
        let ambient = (e.feltBPM <= 95 && e.bassShare < 6) || e.bassShare < 2
        let fresh: ShowStyle = club ? .club : (ambient ? .ambient : .hiphop)
        switch current {
        case nil: return fresh
        case .club?: return .club
        case .hiphop?: return club ? .club : .hiphop
        case .ambient?: return club ? .club : (e.bassShare >= 6 ? .hiphop : .ambient)
        }
    }
}
