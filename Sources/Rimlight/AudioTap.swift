import AudioToolbox
import CoreAudio
import Foundation

/// System audio through a Core Audio process tap (macOS 14.2+): a private, unmuted global stereo tap read via a
/// private aggregate device built on the default output. It reads what the Mac plays; it never opens the mic.
/// macOS asks once for "system audio recording" permission; if it is denied the tap delivers silence.
final class AudioTap {
    struct Failure: Error, CustomStringConvertible {
        let step: String, status: OSStatus
        var description: String { "\(step) failed (\(status))" }
    }

    /// Mono samples and their sample rate, called on the tap's own queue.
    var onSamples: ((UnsafeBufferPointer<Float>, Double) -> Void)?
    /// Called on the main queue after the default output changes and the tap was rebuilt (or failed to).
    var onRebuild: ((Result<Void, Error>) -> Void)?

    private(set) var sampleRate: Double = 48000
    private(set) var outputLatency: Double = 0     // seconds from tap to speaker/headphones
    private(set) var outputName = "?"
    private(set) var running = false

    private let queue = DispatchQueue(label: "com.roshan.rimlight.audio", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var mono = [Float](repeating: 0, count: 4096)
    private var listener: AudioObjectPropertyListenerBlock?

    func start() throws {
        teardown()
        let output = try Self.defaultOutput()
        let outputUID = try Self.stringProperty(output, kAudioDevicePropertyDeviceUID)
        outputName = (try? Self.stringProperty(output, kAudioObjectPropertyName)) ?? "?"
        outputLatency = Self.latency(of: output)

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Rimlight"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "create process tap")
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Rimlight Tap",
            kAudioAggregateDeviceUIDKey: "com.roshan.rimlight.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg), "create aggregate device")
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
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.handle(input)
        }, "create IO proc")
        procID = proc
        try check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
        running = true
        watchDefaultOutput()
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
    }

    private func handle(_ input: UnsafePointer<AudioBufferList>) {
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
        mono.withUnsafeBufferPointer { onSamples?(UnsafeBufferPointer(rebasing: $0[0..<frames]), sampleRate) }
    }

    /// AirPods connect, a display with speakers wakes: rebuild on the new default output.
    private func watchDefaultOutput() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            do { try self.start(); self.onRebuild?(.success(())) } catch { self.onRebuild?(.failure(error)) }
        }
        var addr = Self.defaultOutputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr {
            listener = block
        }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw Failure(step: step, status: status) }
    }

    // MARK: device properties

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

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
