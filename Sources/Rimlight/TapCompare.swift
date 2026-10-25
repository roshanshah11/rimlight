import AudioToolbox
import CoreAudio
import Foundation

/// `rimlight debug-tap-compare <out.txt>`: checks that the tap-only aggregate device stamps samples at the same host
/// time as the old one built on the output device. It plays faint clicks (-66 dBFS) on the built-in speakers, taps
/// its own process through both aggregates at once, and reports how far apart the two see each click.
/// Run it through Launch Services so it uses Rimlight's audio-recording permission:
/// `open -n -W -a ~/Applications/Rimlight.app --args debug-tap-compare /path/out.txt`
extension CLI {
    private final class Onsets: @unchecked Sendable {
        private let lock = NSLock()
        private var quietSince = -Double.infinity
        private var loud = false
        private(set) var times: [Double] = []
        func feed(_ samples: UnsafeBufferPointer<Float>, start: Double, rate: Double) {
            lock.lock(); defer { lock.unlock() }
            for (i, x) in samples.enumerated() {
                let t = start + Double(i) / rate
                if abs(x) > 0.00025 {
                    if !loud, t - quietSince > 0.2 { times.append(t) }
                    loud = true
                } else if loud {
                    loud = false; quietSince = t
                }
            }
        }
        var snapshot: [Double] { lock.lock(); defer { lock.unlock() }; return times }
    }

    nonisolated(unsafe) private static var clickFrame = 0

    static func debugTapCompare(to out: String) -> Bool {
        var log = ""
        func say(_ s: String) { log += s + "\n" }
        defer { try? log.write(toFile: out, atomically: true, encoding: .utf8) }

        // the built-in speakers: never Bluetooth, so the old shape can't flip headphones to headset mode
        guard let speakers = builtInOutput(), let speakersUID = try? AudioTap.stringProperty(speakers, kAudioDevicePropertyDeviceUID)
        else { say("no built-in output"); return false }

        // clicks on the speakers
        var cd = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                           componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &cd) else { say("no HAL output unit"); return false }
        var unit: AudioUnit?
        AudioComponentInstanceNew(comp, &unit)
        guard let au = unit else { say("no audio unit"); return false }
        var dev = speakers
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioObjectID>.size))
        var fmt = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                                              mBitsPerChannel: 32, mReserved: 0)
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var cb = AURenderCallbackStruct(inputProc: { _, _, _, _, frames, data in
            guard let data else { return noErr }
            for buf in UnsafeMutableAudioBufferListPointer(data) {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<Int(frames) { p[f] = (CLI.clickFrame + f) % 24000 < 24 ? 0.0005 : 0 }
            }
            CLI.clickFrame += Int(frames)
            return noErr
        }, inputProcRefCon: nil)
        AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard AudioUnitInitialize(au) == noErr else { say("audio unit init failed"); return false }

        // this process, tapped twice: old shape (on the speakers) and tap-only
        var pid = getpid(), me = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioOutputUnitStart(au)   // the process object exists once it plays
        Thread.sleep(forTimeInterval: 0.5)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &me)
        guard me != kAudioObjectUnknown else { say("no process object"); return false }

        var cleanup: [() -> Void] = [{ AudioOutputUnitStop(au); AudioComponentInstanceDispose(au) }]
        defer { cleanup.reversed().forEach { $0() } }
        let queue = DispatchQueue(label: "tap-compare", qos: .userInteractive)
        func open(_ name: String, output: String?) -> Onsets? {
            let desc = CATapDescription(stereoMixdownOfProcesses: [me])
            desc.name = "Rimlight compare \(name)"; desc.isPrivate = true; desc.muteBehavior = .unmuted
            var tap = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { say("\(name): create tap failed"); return nil }
            var agg = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateAggregateDevice(AudioTap.aggregate(tap: desc.uuid, withOutput: output) as CFDictionary, &agg) == noErr
            else { AudioHardwareDestroyProcessTap(tap); say("\(name): create aggregate failed"); return nil }
            var f = AudioStreamBasicDescription(); var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var fa = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(tap, &fa, 0, nil, &sz, &f)
            let rate = f.mSampleRate > 0 ? f.mSampleRate : 48000
            let onsets = Onsets()
            var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
            let hostSeconds = Double(tb.numer) / Double(tb.denom) / 1e9
            var proc: AudioDeviceIOProcID?
            AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { _, input, inputTime, _, _ in
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = list.first, let d = first.mData, inputTime.pointee.mFlags.contains(.hostTimeValid) else { return }
                let ch = max(1, Int(first.mNumberChannels))
                let n = Int(first.mDataByteSize) / (4 * ch)
                let p = d.assumingMemoryBound(to: Float.self)
                let mono = (0..<n).map { p[$0 * ch] }
                mono.withUnsafeBufferPointer { onsets.feed($0, start: Double(inputTime.pointee.mHostTime) * hostSeconds, rate: rate) }
            }
            AudioDeviceStart(agg, proc)
            cleanup.append {
                AudioDeviceStop(agg, proc); AudioDeviceDestroyIOProcID(agg, proc!)
                AudioHardwareDestroyAggregateDevice(agg); AudioHardwareDestroyProcessTap(tap)
            }
            return onsets
        }
        guard let old = open("old", output: speakersUID), let new = open("tap-only", output: nil) else { return false }
        Thread.sleep(forTimeInterval: 6)

        let a = old.snapshot, b = new.snapshot
        var diffs: [Double] = []
        for t in b { if let m = a.min(by: { abs($0 - t) < abs($1 - t) }), abs(m - t) < 0.1 { diffs.append((t - m) * 1000) } }
        say("clicks heard: old shape \(a.count), tap-only \(b.count), matched \(diffs.count)")
        guard !diffs.isEmpty else { say("no matched clicks"); return false }
        let sorted = diffs.sorted()
        say(String(format: "tap-only minus old, ms: median %.2f, min %.2f, max %.2f", sorted[sorted.count / 2], sorted.first!, sorted.last!))
        return true
    }

    private static func builtInOutput() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { id in
            var t: UInt32 = 0, s = UInt32(4)
            var ta = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &ta, 0, nil, &s, &t) == noErr, t == kAudioDeviceTransportTypeBuiltIn else { return false }
            var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                mElement: kAudioObjectPropertyElementMain)
            var ss: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == noErr && ss > 0
        }
    }
}
