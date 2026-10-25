import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import RimlightCore

/// Measures the current output's delay by ear, without him: eight chirps play through it (his Beats, one earcup held
/// against the MacBook) and the MacBook's own mic times each one (ChirpCalibration). The Beats' mic is never opened,
/// so they stay in stereo. The result replaces macOS's reported latency for that output.
final class ChirpRun: @unchecked Sendable {
    struct Outcome {
        var result: ChirpCalibration.Result; var outputName: String; var outputUID: String
        var reported: Double   // what the light waits for this output now (AudioTap.latency), seconds
        var buffer: Double     // the part of that before the chirps' timestamps: one IO buffer
        var music: MusicSync.Result?   // the tapped song against the mic, when a song was playing
        var debug: [String: Double] = [:]
        /// macOS's own figure for the time a chirp takes from its timestamp to the air, beside the measured one
        var reportedSound: Double { reported - buffer }
        /// Measured on the song: the whole way from the tap to the ear, nothing assumed.
        var musicOK: Bool { music?.ok ?? false }
        var ok: Bool { musicOK || result.ok }
        /// From the tap to the ear: the song's measurement, or the chirps' plus the buffer the tap hears ahead
        var delay: Double { musicOK ? music!.delay : result.latency + buffer }
        /// what to add to the reported latency for this output, ms
        var offsetMs: Double { ((delay - reported) * 1000).rounded() }
    }

    private let rate = 48000.0
    private let lock = NSLock()
    private var played: [Double] = []
    private var recording: [Float] = []
    private var recordingStart: Double?
    private var outFrame = 0
    private let chirp: [Float]
    private var outUnit: AudioUnit?
    private var inUnit: AudioUnit?
    private var inputLatency = 0.0
    private static let hostSeconds: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    init() { chirp = ChirpCalibration.chirp(sampleRate: 48000) }

    /// Play and listen; `output`: a device to play through instead of the default (the built-in speakers for the
    /// self-check). Calls back on the main queue about 5 seconds later.
    func run(output: AudioDeviceID? = nil, tap: TapRecorder? = nil, done: @escaping (Outcome?) -> Void) {
        recording.reserveCapacity(Int(rate * 7))   // the mic thread appends without growing the array
        tap?.arm(seconds: 7)
        guard let mic = Self.builtInMic(), startInput(mic), startOutput(output) else { stopAll(); done(nil); return }
        let dev = output ?? (try? AudioTap.defaultOutput()) ?? 0
        let name = (try? AudioTap.stringProperty(dev, kAudioObjectPropertyName)) ?? "this output"
        let uid = (try? AudioTap.stringProperty(dev, kAudioDevicePropertyDeviceUID)) ?? ""
        let reported = AudioTap.latency(of: dev), buffer = AudioTap.bufferSeconds(of: dev)
        let total = 0.3 + Double(ChirpCalibration.count) * ChirpCalibration.interval + ChirpCalibration.searchWindow + 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { [self] in
            stopAll()
            lock.lock()
            let p = played, rec = recording, start = recordingStart
            lock.unlock()
            guard let start else { done(nil); return }
            // the mic's own delay: a sound reached it this long before its samples arrive
            let r = ChirpCalibration.measure(played: p, recording: rec, recordingStart: start - inputLatency, sampleRate: rate)
            var music: MusicSync.Result?
            var songLevel = 0.0
            if let song = tap?.take(), song.rate == rate, !song.samples.isEmpty {
                songLevel = Double(sqrt(song.samples.reduce(0) { $0 + $1 * $1 } / Float(song.samples.count)))
                if songLevel > 0.003 {
                    music = MusicSync.measure(reference: song.samples, referenceStart: song.start, recording: rec,
                                              recordingStart: start - inputLatency, sampleRate: rate)
                }
            }
            let peak = rec.map { abs($0) }.max() ?? 0
            if ProcessInfo.processInfo.environment["RIM_CHIRP_DUMP"] != nil || FileManager.default.fileExists(atPath: "/tmp/rimlight-chirp-dump") {
                Self.dump(rec, rate: rate, played: p.map { $0 - start })
            }
            done(Outcome(result: r, outputName: name, outputUID: uid, reported: reported, buffer: buffer, music: music,
                         debug: ["played": Double(p.count), "firstPlayedAfterRecording": (p.first ?? 0) - start,
                                 "recordedSeconds": Double(rec.count) / rate, "peak": Double(peak), "inputLatencyMs": inputLatency * 1000,
                                 "songLevel": songLevel]))
        }
    }

    private func stopAll() {
        for u in [outUnit, inUnit].compactMap({ $0 }) { AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u) }
        outUnit = nil; inUnit = nil
    }

    // MARK: output: the chirps

    private func startOutput(_ device: AudioDeviceID?) -> Bool {
        var cd = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                           componentSubType: device == nil ? kAudioUnitSubType_DefaultOutput : kAudioUnitSubType_HALOutput,
                                           componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &cd) else { return false }
        var u: AudioUnit?
        guard AudioComponentInstanceNew(comp, &u) == noErr, let au = u else { return false }
        if var d = device {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        var fmt = Self.format(rate: rate, channels: 2)
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var cb = AURenderCallbackStruct(inputProc: { ref, _, ts, _, frames, data in
            guard let data else { return noErr }
            Unmanaged<ChirpRun>.fromOpaque(ref).takeUnretainedValue().render(ts.pointee, Int(frames), data)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard AudioUnitInitialize(au) == noErr, AudioOutputUnitStart(au) == noErr else { AudioComponentInstanceDispose(au); return false }
        outUnit = au
        return true
    }

    private func render(_ ts: AudioTimeStamp, _ n: Int, _ data: UnsafeMutablePointer<AudioBufferList>) {
        let lead = Int(0.3 * rate), every = Int(ChirpCalibration.interval * rate), len = chirp.count
        let start = ts.mFlags.contains(.hostTimeValid) ? Double(ts.mHostTime) * Self.hostSeconds : CACurrentMediaTime()
        var found: [Double] = []
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        for i in 0..<n {
            let f = outFrame + i - lead
            var v: Float = 0
            if f >= 0 {
                let k = f / every, x = f - k * every
                if k < ChirpCalibration.count, x < len {
                    v = chirp[x] * 0.35
                    if x == 0 { found.append(start + Double(i) / rate) }
                }
            }
            for b in buffers { b.mData?.assumingMemoryBound(to: Float.self)[i] = v }
        }
        outFrame += n
        if !found.isEmpty { lock.lock(); played += found; lock.unlock() }
    }

    // MARK: input: the MacBook's mic

    private var inputBuffer = [Float](repeating: 0, count: 4096)

    private func startInput(_ mic: AudioDeviceID) -> Bool {
        var cd = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                           componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &cd) else { return false }
        var u: AudioUnit?
        guard AudioComponentInstanceNew(comp, &u) == noErr, let au = u else { return false }
        var on: UInt32 = 1, off: UInt32 = 0
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4)
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4)
        var dev = mic
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4) == noErr else {
            AudioComponentInstanceDispose(au); return false
        }
        var fmt = Self.format(rate: rate, channels: 1)
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var cb = AURenderCallbackStruct(inputProc: { ref, flags, ts, bus, frames, _ in
            Unmanaged<ChirpRun>.fromOpaque(ref).takeUnretainedValue().capture(flags, ts, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard AudioUnitInitialize(au) == noErr, AudioOutputUnitStart(au) == noErr else { AudioComponentInstanceDispose(au); return false }
        inUnit = au
        inputLatency = Self.inputLatency(of: mic)
        return true
    }

    private func capture(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ ts: UnsafePointer<AudioTimeStamp>,
                         _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let au = inUnit else { return noErr }
        let n = Int(frames)
        if inputBuffer.count < n { inputBuffer = [Float](repeating: 0, count: n) }
        return inputBuffer.withUnsafeMutableBufferPointer { buf -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4),
                                                                                  mData: UnsafeMutableRawPointer(buf.baseAddress)))
            let st = AudioUnitRender(au, flags, ts, bus, frames, &list)
            guard st == noErr else { return st }
            lock.lock()
            if recordingStart == nil, ts.pointee.mFlags.contains(.hostTimeValid) {
                recordingStart = Double(ts.pointee.mHostTime) * Self.hostSeconds
            }
            recording.append(contentsOf: buf.prefix(n))
            lock.unlock()
            return noErr
        }
    }

    /// Debug: the recording as a WAV and the chirps' times (seconds into it) beside it.
    private static func dump(_ rec: [Float], rate: Double, played: [Double]) {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let n = UInt32(rec.count)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + n * 2); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(n * 2)
        for x in rec { u16(UInt16(bitPattern: Int16(max(-1, min(1, x)) * 32000))) }
        try? d.write(to: URL(fileURLWithPath: "/tmp/rimlight-chirp.wav"))
        try? played.map { String(format: "%.4f", $0) }.joined(separator: "\n").write(toFile: "/tmp/rimlight-chirp-played.txt", atomically: true, encoding: .utf8)
    }

    // MARK: devices

    private static func format(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: channels,
                                    mBitsPerChannel: 32, mReserved: 0)
    }

    static func builtInMic() -> AudioDeviceID? { builtIn(scope: kAudioObjectPropertyScopeInput) }
    static func builtInSpeakers() -> AudioDeviceID? { builtIn(scope: kAudioObjectPropertyScopeOutput) }

    private static func builtIn(scope: AudioObjectPropertyScope) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { id in
            var t: UInt32 = 0, s = UInt32(4)
            var ta = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &ta, 0, nil, &s, &t) == noErr, t == kAudioDeviceTransportTypeBuiltIn else { return false }
            var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var ss: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == noErr && ss > 0
        }
    }

    /// The mic's latency, safety offset and stream latency (input side), seconds.
    private static func inputLatency(of dev: AudioDeviceID) -> Double {
        func u32(_ sel: AudioObjectPropertySelector, _ obj: AudioObjectID, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0, s = UInt32(4)
            return AudioObjectGetPropertyData(obj, &a, 0, nil, &s, &v) == noErr ? v : 0
        }
        var rate: Float64 = 48000, s = UInt32(8)
        var ra = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(dev, &ra, 0, nil, &s, &rate)
        var frames = Double(u32(kAudioDevicePropertyLatency, dev, kAudioObjectPropertyScopeInput))
            + Double(u32(kAudioDevicePropertySafetyOffset, dev, kAudioObjectPropertyScopeInput))
        var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                            mElement: kAudioObjectPropertyElementMain)
        var st = AudioStreamID(0), ss = UInt32(4)
        if AudioObjectGetPropertyData(dev, &sa, 0, nil, &ss, &st) == noErr, st != 0 {
            frames += Double(u32(kAudioStreamPropertyLatency, st, kAudioObjectPropertyScopeGlobal))
        }
        return frames / max(rate, 1)
    }
}

/// The panel: what to do, a Start button, and the result.
final class AutoCalibration: NSObject {
    private let engine: Engine
    private var panel: NSPanel?
    private let text = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private var startButton: NSButton?
    private var run: ChirpRun?
    var onClose: (() -> Void)?
    var onManual: (() -> Void)?

    init(engine: Engine) { self.engine = engine }

    func show(outputName: String, bluetooth: Bool, songPlaying: Bool) {
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "Rimlight timing"
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let song = songPlaying
            ? " Keep the song playing: Rimlight lines up the song as it hears it with what the mic hears, which times the whole way to your ears."
            : " Playing a song first makes it more exact: Rimlight then times the song itself, the whole way to your ears."
        text.stringValue = (bluetooth
            ? "Hold one earcup of \(outputName) right against the MacBook, by the keyboard, then press Start. Eight short chirps play in it; the MacBook's mic times them (the headphones' mic isn't used)."
            : "Keep the room quiet and press Start. Eight short chirps play through \(outputName); the MacBook's mic times them.") + song
        text.font = .systemFont(ofSize: 13)
        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.stringValue = ""
        let start = NSButton(title: "Start", target: self, action: #selector(begin))
        start.keyEquivalent = "\r"
        startButton = start
        let manual = NSButton(title: "Adjust by hand…", target: self, action: #selector(byHand))
        let close = NSButton(title: "Close", target: self, action: #selector(closePanel))
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [manual, close, start])
        let stack = NSStackView(views: [text, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        p.contentView = stack
        p.center()
        NSApp.activate(ignoringOtherApps: true)
        p.orderFrontRegardless()
        p.makeKey()
        panel = p
    }

    @objc private func begin() {
        startButton?.isEnabled = false
        status.stringValue = "Listening…"
        Self.withMic { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.status.stringValue = "Rimlight needs the microphone for this: System Settings › Privacy & Security › Microphone."
                self.startButton?.isEnabled = true
                return
            }
            let r = ChirpRun()
            self.run = r
            r.run(tap: self.engine.tapRecorder) { [weak self] outcome in self?.finished(outcome) }
        }
    }

    private func finished(_ o: ChirpRun.Outcome?) {
        run = nil
        startButton?.isEnabled = true
        startButton?.title = "Again"
        guard let o else { status.stringValue = "Couldn't open the MacBook's mic or the output."; return }
        let r = o.result
        engine.logCalibration(o)
        guard o.ok else {
            status.stringValue = "Heard \(r.heard) of \(ChirpCalibration.count) chirps clearly"
                + (o.music == nil ? "" : " and couldn't line up the song") + ". Hold the earcup closer, turn the volume up, and try again."
            return
        }
        engine.saveMeasuredLatency(uid: o.outputUID, offsetMs: o.offsetMs)
        if o.musicOK {
            status.stringValue = String(format: "%@: the song reaches you %.0f ms after Rimlight hears it (it was waiting %.0f). Saved.",
                                        o.outputName, o.delay * 1000, engine.lightDelayMs)
        } else {
            status.stringValue = String(format: "%@: the sound takes %.0f ms (macOS says %.0f). Saved; the light waits that long now.",
                                        o.outputName, r.latency * 1000, o.reportedSound * 1000)
        }
    }

    @objc private func byHand() { closePanel(); onManual?() }

    @objc private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
        onClose?()
        onClose = nil
    }

    static func withMic(_ then: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: then(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { then(ok) } }
        default: then(false)
        }
    }
}
