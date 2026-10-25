import AudioToolbox
import CoreAudio
import Foundation
import QuartzCore

/// The sound of the apps that are playing, through a Core Audio process tap (macOS 14.2+): a private, unmuted stereo
/// mixdown of just those processes, read via a private aggregate device that holds only the tap. It never opens the
/// mic. macOS asks once for "system audio recording" permission; if it is denied the tap delivers silence.
/// The tap only runs while something plays (a running aggregate device keeps the Mac from idle-sleeping).
final class AudioTap {
    struct Failure: Error, CustomStringConvertible {
        let step: String, status: OSStatus
        var description: String { "\(step) failed (\(status))" }
    }

    /// Mono samples, their sample rate, and the host time (CACurrentMediaTime seconds) of the first sample,
    /// called on the tap's own queue.
    var onSamples: ((UnsafeBufferPointer<Float>, Double, Double) -> Void)?
    /// Called on the main queue after the default output changes and the tap was rebuilt (or failed to).
    var onRebuild: ((Result<Void, Error>) -> Void)?

    private(set) var sampleRate: Double = 48000
    private(set) var outputLatency: Double = 0     // seconds from tap to speaker/headphones
    private(set) var outputName = "?"
    private(set) var running = false
    /// The process objects being listened to, and their names for `rimlight status`.
    private(set) var tapped: [AudioObjectID] = []
    private(set) var tappedNames: [String] = []

    private let queue = DispatchQueue(label: "com.roshan.rimlight.audio", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var mono = [Float](repeating: 0, count: 4096)
    private var listener: AudioObjectPropertyListenerBlock?

    func start(processes: [Player]) throws {
        teardown()
        guard !processes.isEmpty else { return }
        let output = try Self.defaultOutput()
        outputName = (try? Self.stringProperty(output, kAudioObjectPropertyName)) ?? "?"
        outputLatency = Self.latency(of: output)

        let desc = CATapDescription(stereoMixdownOfProcesses: processes.map(\.id))
        desc.name = "Rimlight"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "create process tap")
        tapID = tap

        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(Self.aggregate(tap: desc.uuid) as CFDictionary, &agg),
                  "create aggregate device")
        aggregateID = agg

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format), "read tap format")
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw Failure(step: "tap format is not float", status: -1)
        }
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48000

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, input, inputTime, _, _ in
            self?.handle(input, inputTime.pointee)
        }, "create IO proc")
        procID = proc
        try check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
        running = true
        tapped = processes.map(\.id)
        tappedNames = processes.map(\.name)
        watchDefaultOutput()
    }

    /// A private aggregate device that reads the tap. Only the tap: with the output device as a sub-device, the
    /// aggregate (which has input, the tap) counts as recording on that device, and Bluetooth headphones drop to
    /// headset mode (16 kHz mono) for as long as the tap runs (Beats Studio Pro, 2026-10-24). `withOutput` builds
    /// the old shape, for `rimlight debug-tap-compare` only.
    static func aggregate(tap: UUID, withOutput outputUID: String? = nil) -> [String: Any] {
        var d: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Rimlight Tap",
            kAudioAggregateDeviceUIDKey: "com.roshan.rimlight.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: outputUID != nil,
                                               kAudioSubTapUIDKey: tap.uuidString]],
        ]
        if let outputUID {
            d[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            d[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        return d
    }

    func stop() {
        if let l = listener {
            var addr = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, l)
            listener = nil
        }
        teardown()
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let p = procID {
                AudioDeviceStop(aggregateID, p)
                AudioDeviceDestroyIOProcID(aggregateID, p)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        running = false
        tapped = []
        tappedNames = []
    }

    private static let hostSeconds: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    private func handle(_ input: UnsafePointer<AudioBufferList>, _ ts: AudioTimeStamp) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first, first.mData != nil else { return }
        let frames: Int
        if list.count == 1 {
            let ch = max(1, Int(first.mNumberChannels))
            frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
            let p = first.mData!.assumingMemoryBound(to: Float.self)
            let inv = 1 / Float(ch)
            for f in 0..<frames {
                var s: Float = 0
                for c in 0..<ch { s += p[f * ch + c] }
                mono[f] = s * inv
            }
        } else {
            frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
            for f in 0..<frames { mono[f] = 0 }
            let inv = 1 / Float(list.count)
            for buf in list {
                guard let d = buf.mData else { continue }
                let p = d.assumingMemoryBound(to: Float.self)
                for f in 0..<min(frames, Int(buf.mDataByteSize) / MemoryLayout<Float>.size) { mono[f] += p[f] * inv }
            }
        }
        guard frames > 0 else { return }
        // when the first of these samples was played (the tap's own timestamp; else estimate from now)
        let start = ts.mFlags.contains(.hostTimeValid) ? Double(ts.mHostTime) * Self.hostSeconds
            : CACurrentMediaTime() - Double(frames) / sampleRate
        mono.withUnsafeBufferPointer { onSamples?(UnsafeBufferPointer(rebasing: $0[0..<frames]), sampleRate, start) }
    }

    /// AirPods connect, a display with speakers wakes: rebuild on the new default output.
    private func watchDefaultOutput() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let players = Self.players().filter { self.tapped.contains($0.id) }
            do { try self.start(processes: players); self.onRebuild?(.success(())) } catch { self.onRebuild?(.failure(error)) }
        }
        var addr = Self.defaultOutputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr {
            listener = block
        }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw Failure(step: step, status: status) }
    }

    // MARK: who is playing

    struct Player: Equatable {
        let id: AudioObjectID
        let pid: pid_t
        let name: String
    }

    /// Never listened to: this app, and the iMac stream (it re-plays other apps' sound).
    static let ignored: Set<String> = ["Rimlight", "imac-stream"]

    /// Processes playing sound right now. A process that is also recording (dictation, calls, screen and stream
    /// recorders) doesn't count: it isn't music.
    static func players() -> [Player] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let me = getpid()
        return ids.compactMap { id -> Player? in
            guard u32(id, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal) != 0,
                  u32(id, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal) == 0 else { return nil }
            var pid: pid_t = 0
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var sz = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &pid) == noErr, pid != me else { return nil }
            let name = processName(pid)
            return ignored.contains(name) ? nil : Player(id: id, pid: pid, name: name)
        }
    }

    /// The app's name for a helper ("Comet Helper (Renderer)" -> "Comet"), else the executable's.
    private static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "pid \(pid)" }
        let path = String(cString: buf)
        if let r = path.range(of: ".app/") {
            return String(path[..<r.lowerBound].split(separator: "/").last ?? "")
        }
        return String(path.split(separator: "/").last ?? "")
    }

    // MARK: device properties

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    static func isBluetooth(_ dev: AudioObjectID) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0, s = UInt32(4)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &t) == noErr else { return false }
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    static func defaultOutput() throws -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = defaultOutputAddress
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard st == noErr, id != kAudioObjectUnknown else { throw Failure(step: "find default output", status: st) }
        return id
    }

    static func stringProperty(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        guard st == noErr, let v = value?.takeRetainedValue() else { throw Failure(step: "read string property", status: st) }
        return v as String
    }

    private static func u32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : 0
    }

    /// One IO buffer of the output, seconds: the tap hears a sample this long before its output timestamp.
    static func bufferSeconds(of device: AudioObjectID) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sr: Float64 = 48000
        var size = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &sr)
        return sr > 0 ? Double(u32(device, kAudioDevicePropertyBufferFrameSize)) / sr : 0
    }

    /// Device + safety offset + buffer + stream latency, in seconds. Bluetooth drivers tend to under-report, so a
    /// Bluetooth output gets at least 160 ms (typical AAC on AirPods); the menu's sync slider trims the rest.
    static func latency(of device: AudioObjectID) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sr: Float64 = 48000
        var size = UInt32(MemoryLayout<Float64>.size)
        _ = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &sr)
        var frames = Double(u32(device, kAudioDevicePropertyLatency) + u32(device, kAudioDevicePropertySafetyOffset)
                            + u32(device, kAudioDevicePropertyBufferFrameSize))
        var streamsAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var streamsSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &streamsAddr, 0, nil, &streamsSize) == noErr, streamsSize >= 4 {
            var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(device, &streamsAddr, 0, nil, &streamsSize, &streams) == noErr, let s = streams.first {
                frames += Double(u32(s, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal))
            }
        }
        var seconds = sr > 0 ? frames / sr : 0
        let transport = u32(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            seconds = max(seconds, 0.16)
        }
        return seconds
    }
}
