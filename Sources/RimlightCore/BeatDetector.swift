import Accelerate
import Foundation

/// A detected beat. `time` is in seconds on the detector's own clock (audio consumed so far), at the onset itself,
/// so callers can subtract it from "now" to know how late the detection arrived.
public struct BeatEvent: Equatable, Sendable {
    public var time: Double
    public var strength: Float
}

/// Live, normalized audio features for the renderer. All values are 0...1.
public struct AudioFeatures: Equatable, Sendable {
    public var energy: Float = 0
    public var bass: Float = 0
    public var silent: Bool = true
    public init() {}
}

/// Kick-focused beat detector: spectral flux on the low band (plus a little full-band flux), an adaptive
/// threshold over the last second, peak picking with one frame of lookahead, and a refractory period.
/// Tempo comes from the autocorrelation of the onset envelope over the last six seconds.
public final class BeatDetector {
    public let sampleRate: Double
    public let frameSize: Int
    public let hopSize: Int

    /// Seconds between the onset and the moment `process` can report it (half a frame plus one hop of lookahead).
    public var detectionLatency: Double { Double(frameSize / 2 + hopSize) / sampleRate }
    public var frameRate: Double { sampleRate / Double(hopSize) }

    public private(set) var features = AudioFeatures()
    public private(set) var tempo: Double?          // BPM, nil until confident
    public private(set) var tempoConfidence: Float = 0

    private let log2n: vDSP_Length
    private let fft: FFTSetup
    private var window: [Float]
    private var ring: [Float]                // last frameSize samples
    private var ringFill = 0
    private var pendingHop = 0
    private var samplesConsumed = 0
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var prevLog: [Float]
    private var hasPrev = false
    private let lowBins: ClosedRange<Int>
    private let fullBins: ClosedRange<Int>

    private var onsetHistory: [Float] = []   // ~1 s, for the threshold
    private var envelope: [Float] = []       // ~6 s, for tempo
    private var o1: Float = 0, o2: Float = 0  // o[n-1], o[n-2]
    private var thr1: Float = 0
    private var lastBeatTime = -10.0
    private var framesSinceTempo = 0
    private var energyPeak: Float = 1e-4
    private var bassPeak: Float = 1e-4
    private var onsetPeak: Float = 1e-3
    private var silentFrames = 0
    private var beats: [BeatEvent] = []

    public var refractory: Double = 0.22     // seconds; caps detection at ~270 BPM
    public var sensitivity: Float = 1.5      // threshold = mean + sensitivity * std

    public init(sampleRate: Double, frameSize: Int = 2048, hopSize: Int = 512) {
        precondition(frameSize.nonzeroBitCount == 1, "frameSize must be a power of two")
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.hopSize = hopSize
        log2n = vDSP_Length(log2(Double(frameSize)))
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: frameSize)
        windowed = [Float](repeating: 0, count: frameSize)
        real = [Float](repeating: 0, count: frameSize / 2)
        imag = [Float](repeating: 0, count: frameSize / 2)
        mags = [Float](repeating: 0, count: frameSize / 2)
        prevLog = [Float](repeating: 0, count: frameSize / 2)
        let binHz = sampleRate / Double(frameSize)
        let bin = { (hz: Double) in max(1, min(frameSize / 2 - 1, Int((hz / binHz).rounded()))) }
        lowBins = bin(35)...max(bin(35), bin(150))
        fullBins = 1...bin(8000)
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Feed mono samples. Returns beats detected in this call (also kept for `drainBeats`).
    @discardableResult
    public func process(_ samples: UnsafeBufferPointer<Float>) -> [BeatEvent] {
        var found: [BeatEvent] = []
        var i = 0
        while i < samples.count {
            let take = min(hopSize - pendingHop, samples.count - i)
            // shift the ring left by `take` and append
            if take > 0 {
                ring.withUnsafeMutableBufferPointer { r in
                    let base = r.baseAddress!
                    memmove(base, base + take, (frameSize - take) * MemoryLayout<Float>.size)
                    memcpy(base + frameSize - take, samples.baseAddress! + i, take * MemoryLayout<Float>.size)
                }
            }
            ringFill = min(frameSize, ringFill + take)
            pendingHop += take
            samplesConsumed += take
            i += take
            if pendingHop == hopSize {
                pendingHop = 0
                if ringFill == frameSize, let b = analyzeFrame() { found.append(b) }
            }
        }
        beats.append(contentsOf: found)
        return found
    }

    public func process(_ samples: [Float]) -> [BeatEvent] {
        samples.withUnsafeBufferPointer { process($0) }
    }

    public func drainBeats() -> [BeatEvent] {
        defer { beats.removeAll(keepingCapacity: true) }
        return beats
    }

    /// Detector clock: seconds of audio consumed.
    public var time: Double { Double(samplesConsumed) / sampleRate }

    private func analyzeFrame() -> BeatEvent? {
        let n = frameSize
        vDSP_vmul(ring, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var rms: Float = 0
        vDSP_rmsqv(ring, 1, &rms, vDSP_Length(n))

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }

        // log-compressed magnitude per bin; flux = positive change since last frame
        var lowFlux: Float = 0, fullFlux: Float = 0, bassMag: Float = 0
        let scale = 1 / Float(n)
        for k in fullBins {
            let m = sqrtf(mags[k]) * scale
            let l = log1pf(1000 * m)
            if hasPrev {
                let d = l - prevLog[k]
                if d > 0 {
                    fullFlux += d
                    if lowBins.contains(k) { lowFlux += d }
                }
            }
            if lowBins.contains(k) { bassMag += m }
            prevLog[k] = l
        }
        let firstFrame = !hasPrev
        hasPrev = true
        lowFlux /= Float(lowBins.count)
        fullFlux /= Float(fullBins.count)
        let onset = firstFrame ? 0 : 0.8 * lowFlux + 0.2 * fullFlux

        // features (AGC so quiet and loud songs both use the full range)
        let silent = rms < 2e-4
        silentFrames = silent ? silentFrames + 1 : 0
        energyPeak = max(rms, energyPeak * 0.9995, 1e-4)
        bassPeak = max(bassMag, bassPeak * 0.9995, 1e-5)
        let e = silent ? 0 : min(1, rms / energyPeak)
        let b = silent ? 0 : min(1, bassMag / bassPeak)
        features.energy += (e - features.energy) * (e > features.energy ? 0.5 : 0.06)
        features.bass += (b - features.bass) * (b > features.bass ? 0.6 : 0.10)
        features.silent = silentFrames > Int(frameRate * 0.5)

        // adaptive threshold over ~1 s
        let histLen = Int(frameRate)
        onsetHistory.append(onset)
        if onsetHistory.count > histLen { onsetHistory.removeFirst(onsetHistory.count - histLen) }
        var mean: Float = 0, std: Float = 0
        vDSP_normalize(onsetHistory, 1, nil, 1, &mean, &std, vDSP_Length(onsetHistory.count))
        let thr = mean + sensitivity * std + 0.002

        envelope.append(onset)
        let envLen = Int(frameRate * 6)
        if envelope.count > envLen { envelope.removeFirst(envelope.count - envLen) }
        framesSinceTempo += 1
        if framesSinceTempo >= Int(frameRate / 2), envelope.count >= Int(frameRate * 3) {
            framesSinceTempo = 0
            estimateTempo()
        }

        // peak at n-1: above its threshold, rising into it and falling after it
        var event: BeatEvent?
        let frameTime = { (back: Int) -> Double in
            // centre of the frame `back` hops ago
            (Double(self.samplesConsumed - back * self.hopSize) - Double(self.frameSize) / 2) / self.sampleRate
        }
        let t1 = frameTime(1)
        if !silent, o1 > thr1, o1 >= o2, o1 > onset, t1 - lastBeatTime >= refractory {
            onsetPeak = max(o1, onsetPeak * 0.995)
            lastBeatTime = t1
            event = BeatEvent(time: t1, strength: min(1, max(0.25, o1 / onsetPeak)))
        } else {
            onsetPeak = max(onsetPeak * 0.9995, 1e-3)
        }
        o2 = o1
        o1 = onset
        thr1 = thr
        return event
    }

    private func estimateTempo() {
        let x = envelope
        let count = x.count
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(count))
        var c = [Float](repeating: 0, count: count)
        vDSP_vsadd(x, 1, [-mean], &c, 1, vDSP_Length(count))
        var r0: Float = 0
        vDSP_dotpr(c, 1, c, 1, &r0, vDSP_Length(count))
        guard r0 > 1e-9 else { tempo = nil; tempoConfidence = 0; return }

        let fr = frameRate
        let minLag = Int((fr * 60 / 190).rounded(.down))
        let maxLag = min(count - 1, Int((fr * 60 / 65).rounded(.up)))
        guard maxLag > minLag + 2 else { return }
        var acf = [Float](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) where lag > 0 && lag < count {
            var s: Float = 0
            vDSP_dotpr(c, 1, Array(c[lag...]), 1, &s, vDSP_Length(count - lag))
            acf[lag] = s / r0
        }
        // perceptual weighting: favour ~120 BPM, one-octave log-Gaussian
        var best = minLag, bestScore: Float = -1
        for lag in minLag...maxLag {
            let bpm = 60 * fr / Double(lag)
            let w = Float(exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2)))
            let score = acf[lag] * w
            if score > bestScore { bestScore = score; best = lag }
        }
        // parabolic refinement
        let a = acf[best - 1], b = acf[best], cc = acf[best + 1]
        let denom = a - 2 * b + cc
        let offset = denom != 0 ? 0.5 * (a - cc) / denom : 0
        let lag = Double(best) + Double(max(-0.5, min(0.5, offset)))
        tempoConfidence = max(0, min(1, b))
        tempo = tempoConfidence > 0.08 ? 60 * fr / lag : nil
    }
}
