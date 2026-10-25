import AppKit
import AudioToolbox
import CoreAudio
import RimlightCore

/// The timing check for whatever the sound comes out of, Bluetooth headphones above all (macOS reports AirPods-class
/// headphones at a fixed ~160 ms while the real delay runs 155-180 ms and drifts). Clicks play through the output
/// while the rim flashes white on each one; the arrow keys move the flash until the two land together (→ later,
/// ← earlier), Return saves
/// the offset for that output (applied whenever it's the output again), Esc leaves it as it was.
/// `rimlight calibrate` or the menu's "Calibrate timing…" starts it.
final class Calibration: NSObject {
    static let interval = 0.75     // seconds between clicks: 80 a minute, an accent every 4th

    let outputUID: String
    let outputName: String
    private(set) var offsetMs: Double
    var onFinish: ((_ save: Bool) -> Void)?
    var onChange: (() -> Void)?

    private let clicks = ClickTrack()
    private var unit: AudioUnit?
    private var panel: KeyPanel?
    private let readout = NSTextField(labelWithString: "")
    private let latencyMs: Double

    init(outputUID: String, outputName: String, offsetMs: Double, latency: Double) {
        self.outputUID = outputUID
        self.outputName = outputName
        self.offsetMs = offsetMs
        latencyMs = latency * 1000
        super.init()
    }

    // MARK: light

    /// The look at sound time `t`: a dim base and a white flash on each click (at most 1.3 a second).
    func light(at t: Double) -> LightState {
        var l = LightState()
        l.section = .quiet
        l.master = 0.3
        l.bloom = 0.8
        l.wash = SIMD3(0.35, 0.4, 0.55)
        l.washLevel = 0.8
        l.colorA = l.wash; l.colorB = l.wash
        l.fixtures = 2
        l.fixtureLevel = 0.3
        if let c = clicks.last(atOrBefore: t) {
            l.flash = Float(exp(-(t - c.time) / 0.07)) * (c.accent ? 1 : 0.75)
        }
        return l
    }

    // MARK: lifecycle

    func start() {
        guard startClicks() else { finish(save: false); return }
        showPanel()
        // never left running: it stops itself after two minutes (unsaved)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.finish(save: false) }
    }

    func save() { finish(save: true) }
    func earlier() { nudge(-10) }
    func later() { nudge(10) }

    private func finish(save: Bool) {
        guard onFinish != nil else { return }   // already finished
        if let u = unit { AudioOutputUnitStop(u); AudioComponentInstanceDispose(u); unit = nil }
        panel?.orderOut(nil)
        panel = nil
        onFinish?(save)
        onFinish = nil
    }

    func cancel() { finish(save: false) }

    private func nudge(_ ms: Double) {
        offsetMs = min(400, max(-400, offsetMs + ms))
        updateReadout()
        onChange?()
    }

    // MARK: sound

    private func startClicks() -> Bool {
        var cd = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_DefaultOutput,
                                           componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &cd) else { return false }
        var u: AudioUnit?
        guard AudioComponentInstanceNew(comp, &u) == noErr, let au = u else { return false }
        var fmt = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                                              mBitsPerChannel: 32, mReserved: 0)
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt,
                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var cb = AURenderCallbackStruct(inputProc: { ref, _, ts, _, frames, data in
            guard let data else { return noErr }
            Unmanaged<ClickTrack>.fromOpaque(ref).takeUnretainedValue().render(ts.pointee, Int(frames), data)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(clicks).toOpaque())
        AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard AudioUnitInitialize(au) == noErr, AudioOutputUnitStart(au) == noErr else {
            AudioComponentInstanceDispose(au)
            return false
        }
        unit = au
        return true
    }

    // MARK: panel

    private func showPanel() {
        let p = KeyPanel(contentRect: CGRect(x: 0, y: 0, width: 470, height: 214), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        p.title = "Rimlight timing"
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false   // a panel hides when its app isn't frontmost, and a menu-bar app rarely is
        p.onKey = { [weak self] e in self?.key(e) ?? false }
        p.onClose = { [weak self] in self?.finish(save: false) }
        let text = NSTextField(wrappingLabelWithString: """
            Clicks are playing in \(outputName), and the rim flashes white on each one. Move the flash until it \
            lands on the click: Later / Earlier (or → and ←, ⌥ for small steps). Save keeps it for \
            \(outputName); Cancel (or Esc) leaves it as it was.
            """)
        text.font = .systemFont(ofSize: 13)
        readout.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        readout.alignment = .center
        func button(_ title: String, _ action: Selector, key: String = "") -> NSButton {
            let b = FirstClickButton(title: title, target: self, action: action)
            b.keyEquivalent = key
            return b
        }
        let buttons = NSStackView(views: [button("Earlier", #selector(tapEarlier)), button("Later", #selector(tapLater)),
                                          button("Cancel", #selector(tapCancel), key: "\u{1b}"), button("Save", #selector(tapSave), key: "\r")])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [text, readout, buttons])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        p.contentView = stack
        updateReadout()
        p.center()
        NSApp.activate(ignoringOtherApps: true)
        p.orderFrontRegardless()
        p.makeKey()
        panel = p
    }

    @objc private func tapEarlier() { nudge(-10) }
    @objc private func tapLater() { nudge(10) }
    @objc private func tapSave() { finish(save: true) }
    @objc private func tapCancel() { finish(save: false) }

    private func updateReadout() {
        readout.stringValue = String(format: "%+.0f ms   (the light waits %.0f ms)", offsetMs, latencyMs + offsetMs)
    }

    private func key(_ e: NSEvent) -> Bool {
        let small = e.modifierFlags.contains(.option)
        switch e.keyCode {
        case 123: nudge(small ? -2 : -10); return true     // ←: the flash earlier
        case 124: nudge(small ? 2 : 10); return true       // →: the flash later
        case 36, 76: finish(save: true); return true        // Return, Enter
        case 53: finish(save: false); return true           // Esc
        default: return false
        }
    }
}

/// The clicks, rendered on the output's own thread; each click's sound time is kept for the flash.
final class ClickTrack: @unchecked Sendable {
    struct Click { var time: Double; var accent: Bool }
    private let lock = NSLock()
    private var recent: [Click] = []
    private var frame = 0
    private let rate = 48000.0
    private static let hostSeconds: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    func render(_ ts: AudioTimeStamp, _ n: Int, _ data: UnsafeMutablePointer<AudioBufferList>) {
        let every = Int(Calibration.interval * rate), len = Int(0.012 * rate)
        let start = ts.mFlags.contains(.hostTimeValid) ? Double(ts.mHostTime) * Self.hostSeconds : CACurrentMediaTime()
        var found: [Click] = []
        for buf in UnsafeMutableAudioBufferListPointer(data) {
            guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<n {
                let f = frame + i, k = f / every, x = f - k * every
                var v: Float = 0
                if x < len {
                    let s = Double(x) / rate, accent = k % 4 == 0
                    // a woodblock-ish tick: a bright tone over a short thump, 12 ms
                    v = Float((sin(2 * .pi * (accent ? 2000 : 1500) * s) * 0.5 + sin(2 * .pi * 180 * s) * 0.5) * exp(-s * 320)) * 0.5
                    if x == 0, buf.mData == data.pointee.mBuffers.mData {
                        found.append(Click(time: start + Double(i) / rate, accent: accent))
                    }
                }
                p[i] = v
            }
        }
        frame += n
        guard !found.isEmpty else { return }
        lock.lock()
        recent += found
        if recent.count > 8 { recent.removeFirst(recent.count - 8) }
        lock.unlock()
    }

    func last(atOrBefore t: Double) -> Click? {
        lock.lock(); defer { lock.unlock() }
        return recent.last { $0.time <= t }
    }
}

/// A button that works on the first click, even while another app is frontmost.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A small panel that takes the arrow keys while it's in front.
private final class KeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    override func close() { super.close(); onClose?(); onClose = nil }
}
