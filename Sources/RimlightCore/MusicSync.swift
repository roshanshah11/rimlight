import Accelerate
import Foundation

/// The whole delay from what the tap hears to what reaches the ear, measured on the song itself: the tapped audio
/// against the MacBook mic's recording of the headphones (an earcup held to it), lined up by cross-correlation.
/// This covers everything between the tap and the air (the tap's own timestamps, buffers, the Bluetooth link), where
/// the chirps only time the output from its timestamp on. Weighted by phase only (GCC-PHAT), so the earcup's tinny
/// sound and the room don't move the peak; 300 Hz to 8 kHz, above desk rumble and below what the mic loses.
public enum MusicSync {
    public struct Result: Equatable, Sendable {
        public var delay: Double          // seconds from tap sound time to the mic hearing it
        public var clarity: Double        // the peak over the strongest rival more than 2 ms away
        public var halves: [Double]       // the delay from each half of the recording on its own
        /// Both halves agree within a millisecond and the peak stands clear.
        public var ok: Bool {
            guard halves.count == 2 else { return false }
            return clarity >= 2 && abs(halves[0] - halves[1]) < 0.001 && abs(delay - halves[0]) < 0.001
        }
    }

    public static let maxDelay = 0.45

    /// `reference`: the tapped audio, mono, sample 0 at host time `referenceStart`; `recording`: the mic, sample 0
    /// heard at `recordingStart` (its input latency already taken off). Uses the stretch both cover, minus `maxDelay`.
    public static func measure(reference: [Float], referenceStart: Double, recording: [Float], recordingStart: Double,
                               sampleRate: Double) -> Result? {
        let from = max(referenceStart, recordingStart)
        let to = min(referenceStart + Double(reference.count) / sampleRate,
                     recordingStart + Double(recording.count) / sampleRate - maxDelay)
        guard to - from >= 2 else { return nil }
        guard let whole = correlate(reference, referenceStart, recording, recordingStart, sampleRate, from, to) else { return nil }
        let mid = (from + to) / 2
        let halves = [correlate(reference, referenceStart, recording, recordingStart, sampleRate, from, mid),
                      correlate(reference, referenceStart, recording, recordingStart, sampleRate, mid, to)].compactMap { $0?.delay }
        return Result(delay: whole.delay, clarity: whole.clarity, halves: halves)
    }

    /// The lag (0 to maxDelay) at which the recording best matches the reference over host times from..<to.
    private static func correlate(_ ref: [Float], _ refStart: Double, _ rec: [Float], _ recStart: Double, _ rate: Double,
                                  _ from: Double, _ to: Double) -> (delay: Double, clarity: Double)? {
        let n = Int((to - from) * rate), lags = Int(maxDelay * rate)
        let ia = Int(((from - refStart) * rate).rounded()), ib = Int(((from - recStart) * rate).rounded())
        guard n > 0, ia >= 0, ib >= 0, ia + n <= ref.count, ib + n + lags <= rec.count else { return nil }
        // the sub-sample part of where the two streams' sample grids sit against each other
        let skew = ((from - recStart) * rate - Double(ib)) - ((from - refStart) * rate - Double(ia))
        var size = 1
        while size < n + lags + n { size <<= 1 }
        let log2n = vDSP_Length(Int(log2(Double(size))))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        let half = size / 2

        func spectrum(_ x: ArraySlice<Float>) -> ([Float], [Float]) {
            var padded = [Float](repeating: 0, count: size)
            // a gentle fade at both ends so the cut edges don't correlate
            let fadeLen = min(x.count / 8, Int(0.01 * rate))
            for (i, v) in x.enumerated() {
                var w: Float = 1
                if i < fadeLen { w = Float(i) / Float(fadeLen) } else if x.count - i < fadeLen { w = Float(x.count - i) / Float(fadeLen) }
                padded[i] = v * w
            }
            var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    padded.withUnsafeBytes { p in
                        vDSP_ctoz(p.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    fft.forward(input: split, output: &split)
                }
            }
            return (re, im)
        }
        let (xr, xi) = spectrum(ref[ia..<(ia + n)])
        let (yr, yi) = spectrum(rec[ib..<(ib + n + lags)])
        // cross-spectrum conj(X) * Y, phase only, 300 Hz to 8 kHz
        var gr = [Float](repeating: 0, count: half), gi = [Float](repeating: 0, count: half)
        let lo = Int(300 / rate * Double(size)), hi = min(half - 1, Int(8000 / rate * Double(size)))
        for k in max(1, lo)...hi {
            let r = xr[k] * yr[k] + xi[k] * yi[k]
            let i = xr[k] * yi[k] - xi[k] * yr[k]
            let m = (r * r + i * i).squareRoot()
            guard m > 1e-20 else { continue }
            gr[k] = r / m; gi[k] = i / m
        }
        var out = [Float](repeating: 0, count: size)
        gr.withUnsafeMutableBufferPointer { r in
            gi.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                fft.inverse(input: split, output: &split)
                out.withUnsafeMutableBytes { p in
                    vDSP_ztoc(&split, 1, p.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half))
                }
            }
        }
        let corr = Array(out[0..<lags])
        guard let peak = corr.indices.max(by: { corr[$0] < corr[$1] }), peak > 0, peak < lags - 1, corr[peak] > 0 else { return nil }
        let away = Int(0.002 * rate)
        let rival = corr.indices.filter { abs($0 - peak) > away }.map { corr[$0] }.max() ?? 0
        let a = corr[peak - 1], b = corr[peak], c = corr[peak + 1]
        let den = a - 2 * b + c
        let frac = den != 0 ? Double(max(-0.5, min(0.5, 0.5 * (a - c) / den))) : 0
        return ((Double(peak) + frac - skew) / rate, Double(b / max(rival, 1e-9)))
    }
}
