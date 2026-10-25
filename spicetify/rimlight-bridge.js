// Rimlight bridge (Spicetify extension): tells Rimlight what Spotify is playing, where in the track it is, the
// track's synced lyrics and, when Spotify has one, its beat map. Talks only to ws://127.0.0.1:47811 on this Mac.
// Install: ../install-bridge.sh
(function rimlightBridge() {
  const S = window.Spicetify;
  if (!S || !S.Player || !S.Player.addEventListener || !S.CosmosAsync || !S.Platform) {
    setTimeout(rimlightBridge, 300);
    return;
  }

  const URL = "ws://127.0.0.1:47811";
  let ws = null;
  let lastUri = null;
  const sentExtras = new Set();   // uris whose lyrics / analysis were already fetched this session

  function send(obj) {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
  }

  function item() {
    return S.Player.data && S.Player.data.item;
  }

  function trackMessage(it) {
    const md = it.metadata || {};
    const artists = (it.artists || []).map((a) => a.name).filter(Boolean);
    const dur = (it.duration && it.duration.milliseconds) || Number(md.duration) || undefined;
    return {
      type: "track",
      uri: it.uri,
      name: it.name || md.title,
      artist: artists.length ? artists.join(", ") : md.artist_name,
      album: (it.album && it.album.name) || md.album_title,
      image: md.image_xlarge_url || md.image_large_url || md.image_url,
      durationMs: dur,
    };
  }

  function sendState() {
    send({
      type: "state",
      paused: !S.Player.isPlaying(),
      progressMs: S.Player.getProgress(),
      sentAt: Date.now(),
    });
  }

  function trackId(uri) {
    const p = (uri || "").split(":");
    return p.length === 3 && p[1] === "track" ? p[2] : null;
  }

  async function sendLyrics(uri) {
    const id = trackId(uri);
    if (!id) return;
    try {
      const r = await S.CosmosAsync.get(
        `https://spclient.wg.spotify.com/color-lyrics/v2/track/${id}?format=json&vocalRemoval=false&market=from_token`,
        null,
        { "app-platform": "WebPlayer", "spotify-app-version": S.Platform.version }
      );
      const l = r && r.lyrics;
      if (!l || !Array.isArray(l.lines)) throw new Error("no lyrics");
      send({
        type: "lyrics",
        uri,
        synced: l.syncType === "LINE_SYNCED",
        lines: l.lines.map((x) => ({ t: Number(x.startTimeMs) || 0, w: x.words || "" })),
      });
    } catch (e) {
      send({ type: "unavailable", kind: "lyrics", uri });
    }
  }

  async function sendAnalysis(uri) {
    const id = trackId(uri);
    if (!id) return;
    try {
      const a = await S.CosmosAsync.get(`https://spclient.wg.spotify.com/audio-attributes/v1/audio-analysis/${id}?format=json`);
      if (!a || !Array.isArray(a.beats) || !a.beats.length) throw new Error("no analysis");
      // each beat's loudness: the loudest segment that overlaps it (segments are ~0.1-0.5 s, sorted by start)
      const segs = Array.isArray(a.segments) ? a.segments : [];
      let j = 0;
      const loudness = a.beats.map((b) => {
        const end = b.start + (b.duration || 0.5);
        while (j < segs.length && segs[j].start + segs[j].duration <= b.start) j++;
        let best = -60;
        for (let k = j; k < segs.length && segs[k].start < end; k++) best = Math.max(best, segs[k].loudness_max);
        return Math.round(best * 100) / 100;
      });
      send({
        type: "analysis",
        uri,
        tempo: (a.track && a.track.tempo) || 0,
        beats: a.beats.map((b) => [b.start, b.confidence]),
        bars: (a.bars || []).map((b) => b.start),
        sections: (a.sections || []).map((s) => [s.start, s.duration, s.loudness]),
        loudness,
      });
    } catch (e) {
      send({ type: "unavailable", kind: "analysis", uri });
    }
  }

  function announce(force) {
    const it = item();
    if (!it || !it.uri) return;
    const changed = it.uri !== lastUri;
    if (changed || force) {
      lastUri = it.uri;
      send(trackMessage(it));
    }
    sendState();
    if (changed || force) {
      // lyrics and the beat map can be re-sent after a reconnect; Rimlight keeps only the current track's
      if (force || !sentExtras.has(it.uri)) {
        sentExtras.add(it.uri);
        sendLyrics(it.uri);
        sendAnalysis(it.uri);
      }
    }
  }

  function connect() {
    try {
      ws = new WebSocket(URL);
    } catch (e) {
      setTimeout(connect, 3000);
      return;
    }
    ws.onopen = () => {
      send({ type: "hello", version: 1 });
      announce(true);
    };
    ws.onclose = () => {
      ws = null;
      setTimeout(connect, 3000);
    };
    ws.onerror = () => {};
  }

  S.Player.addEventListener("songchange", () => announce(false));
  S.Player.addEventListener("onplaypause", sendState);

  // seeks: report when the position jumps away from where it should be
  let lastProgress = 0, lastAt = Date.now();
  S.Player.addEventListener("onprogress", () => {
    const p = S.Player.getProgress(), now = Date.now();
    const expected = lastProgress + (S.Player.isPlaying() ? now - lastAt : 0);
    if (Math.abs(p - expected) > 1500) sendState();
    lastProgress = p;
    lastAt = now;
  });
  // and a periodic correction so the clock never drifts far
  setInterval(() => { if (S.Player.isPlaying()) sendState(); }, 5000);

  connect();
})();
