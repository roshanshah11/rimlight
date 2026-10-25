import Foundation

public struct RGB: Codable, Equatable, Sendable {
    public var r: Double, g: Double, b: Double   // sRGB, 0...1
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    public var hsv: (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    public init(h: Double, s: Double, v: Double) {
        let i = floor(h * 6), f = h * 6 - i
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: self.init(v, t, p)
        case 1: self.init(q, v, p)
        case 2: self.init(p, v, t)
        case 3: self.init(p, q, v)
        case 4: self.init(t, p, v)
        default: self.init(v, p, q)
        }
    }

    /// sRGB → linear, for the shader.
    public var linear: (Double, Double, Double) {
        func l(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return (l(r), l(g), l(b))
    }

    func distance(_ o: RGB) -> Double {
        let dr = r - o.r, dg = g - o.g, db = b - o.b
        return (2 * dr * dr + 4 * dg * dg + 3 * db * db).squareRoot()
    }
}

/// Oklab / OKLCH: a perceptual color space, so "how colorful" and "which hue" mean what they look like.
public struct OKLCH: Equatable, Sendable {
    public var l: Double, c: Double, h: Double   // lightness 0...1, chroma ~0...0.37, hue radians

    public init(l: Double, c: Double, h: Double) { self.l = l; self.c = c; self.h = h }

    public init(_ rgb: RGB) {
        let (r, g, b) = rgb.linear
        let l_ = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m_ = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s_ = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        let A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        let B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        self.init(l: L, c: (A * A + B * B).squareRoot(), h: atan2(B, A))
    }

    /// Linear sRGB, possibly out of gamut.
    var linearRGB: (Double, Double, Double) {
        let A = c * cos(h), B = c * sin(h)
        let l_ = l + 0.3963377774 * A + 0.2158037573 * B
        let m_ = l - 0.1055613458 * A - 0.0638541728 * B
        let s_ = l - 0.0894841775 * A - 1.2914855480 * B
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        return (4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
                -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
                -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S)
    }

    /// sRGB, with chroma reduced until the color fits the gamut (hue and lightness kept).
    public var rgb: RGB {
        var x = self
        for _ in 0..<40 {
            let (r, g, b) = x.linearRGB
            if min(r, g, b) >= -1e-4, max(r, g, b) <= 1 + 1e-4 { break }
            x.c *= 0.94
        }
        let (r, g, b) = x.linearRGB
        func enc(_ v: Double) -> Double {
            let c = min(1, max(0, v))
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return RGB(enc(r), enc(g), enc(b))
    }

    /// Hue distance in degrees, 0...180.
    public func hueDistance(_ o: OKLCH) -> Double {
        let d = abs(h - o.h) * 180 / .pi
        return min(d, 360 - d)
    }
}

/// Light colors from album art, chosen the way Material You picks a wallpaper's seed colors
/// (material-color-utilities score.ts): keep hues that cover a real share of the image and are clearly colorful,
/// rank by share (70%) and chroma, then take colors as far apart in hue as possible (90° down to 40°, at most
/// three; near-duplicates make a flat show). Each pick becomes the most saturated bright light of its hue, the
/// way an LED fixture shows a color. A cover with one real hue pairs it with a white tinted toward it (color plus
/// white is the classic lighting pairing); a cover with none gives warm and cool white.
public enum Palette {
    public static let fallback = [RGB(0.55, 0.36, 1.0), RGB(0.20, 0.62, 1.0), RGB(1.0, 0.36, 0.72)]
    /// For black-and-white or grey covers: a warm and a cool white.
    public static let whites = [OKLCH(l: 0.92, c: 0.035, h: 70 * .pi / 180).rgb, OKLCH(l: 0.88, c: 0.04, h: 250 * .pi / 180).rgb]

    // score.ts uses HCT chroma (target 48, cutoff 5); OKLCH chroma is ~1/370 of that scale
    static let chromaScale = 370.0
    // score.ts cuts at chroma 5; that lets near-black pixels with a faint cast through, and boosting them to a
    // vivid light invents colors the cover doesn't have, so a candidate needs chroma 13 (OKLCH ~0.035)
    static let targetChroma = 48.0, cutoffChroma = 13.0, cutoffProportion = 0.01, minHueSpacing = 40.0
    static let weightProportion = 0.7, weightChromaAbove = 0.3, weightChromaBelow = 0.1

    /// Up to `count` light colors from RGBA8 pixels (pass a downsampled image, ~48×48).
    public static func extract(rgba: [UInt8], count: Int = 3) -> [RGB] {
        var pts: [OKLCH] = []
        pts.reserveCapacity(rgba.count / 4)
        var i = 0
        while i + 3 < rgba.count {
            if rgba[i + 3] > 128 {
                pts.append(OKLCH(RGB(Double(rgba[i]) / 255, Double(rgba[i + 1]) / 255, Double(rgba[i + 2]) / 255)))
            }
            i += 4
        }
        guard pts.count >= 4 else { return fallback }

        // share of the image per hue degree, then summed over a 30° neighborhood (score.ts "excited" proportion)
        var hueShare = [Double](repeating: 0, count: 360)
        for p in pts where p.c * chromaScale >= cutoffChroma { hueShare[degree(p.h)] += 1 / Double(pts.count) }
        var excited = [Double](repeating: 0, count: 360)
        for h in 0..<360 where hueShare[h] > 0 {
            for n in (h - 14)..<(h + 16) { excited[(n + 360) % 360] += hueShare[h] }
        }

        // candidate colors: k-means centers in Oklab
        let centers = kmeans(pts, k: min(8, pts.count))
        let scored = centers.compactMap { c -> (OKLCH, Double)? in
            let chroma = c.c * chromaScale
            let share = excited[degree(c.h)]
            guard chroma >= cutoffChroma, share > cutoffProportion else { return nil }
            let w = chroma < targetChroma ? weightChromaBelow : weightChromaAbove
            return (c, share * 100 * weightProportion + (chroma - targetChroma) * w)
        }.sorted { $0.1 > $1.1 }
        guard !scored.isEmpty else { return whites }

        var chosen: [OKLCH] = []
        for minDistance in stride(from: 90.0, through: minHueSpacing, by: -1) {
            chosen = []
            for (c, _) in scored where chosen.allSatisfy({ $0.hueDistance(c) >= minDistance }) {
                chosen.append(c)
                if chosen.count == count { break }
            }
            if chosen.count >= count { break }
        }
        var lights = chosen.map(light)
        if lights.count == 1 { lights.append(OKLCH(l: 0.95, c: 0.035, h: chosen[0].h).rgb) }
        return lights
    }

    /// The color as light: its hue at the lightness where that hue can be most saturated (weighted toward
    /// bright), at 92% of the most chroma sRGB allows there, so it never clips.
    public static func light(_ c: OKLCH) -> RGB {
        var best = (l: 0.7, c: 0.1, score: -1.0)
        for step in 0...21 {
            let l = 0.5 + Double(step) * 0.02
            let m = maxChroma(l: l, h: c.h)
            let score = m * l.squareRoot()
            if score > best.score { best = (l, m, score) }
        }
        return OKLCH(l: best.l, c: best.c * 0.92, h: c.h).rgb
    }

    static func maxChroma(l: Double, h: Double) -> Double {
        var lo = 0.0, hi = 0.4
        for _ in 0..<18 {
            let mid = (lo + hi) / 2
            let (r, g, b) = OKLCH(l: l, c: mid, h: h).linearRGB
            if min(r, g, b) >= 0, max(r, g, b) <= 1 { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// A custom color made usable as light (keeps whites white).
    public static func glowable(_ c: RGB) -> RGB {
        let o = OKLCH(c)
        return o.c * chromaScale < cutoffChroma ? OKLCH(l: max(o.l, 0.88), c: o.c, h: o.h).rgb : light(o)
    }

    private static func degree(_ h: Double) -> Int {
        (Int((h * 180 / .pi).rounded()) % 360 + 360) % 360
    }

    private static func kmeans(_ pts: [OKLCH], k: Int) -> [OKLCH] {
        // work in Oklab (a, b) so hue wraps correctly
        let lab = pts.map { (l: $0.l, a: $0.c * cos($0.h), b: $0.c * sin($0.h)) }
        let sorted = lab.indices.sorted { lab[$0].l + 2 * hypot(lab[$0].a, lab[$0].b) < lab[$1].l + 2 * hypot(lab[$1].a, lab[$1].b) }
        var centers = (0..<k).map { lab[sorted[($0 * 2 + 1) * sorted.count / (k * 2)]] }
        var assign = [Int](repeating: 0, count: lab.count)
        for _ in 0..<10 {
            for (pi, p) in lab.enumerated() {
                var best = 0, bd = Double.infinity
                for (ci, c) in centers.enumerated() {
                    let d = (p.l - c.l) * (p.l - c.l) + (p.a - c.a) * (p.a - c.a) + (p.b - c.b) * (p.b - c.b)
                    if d < bd { bd = d; best = ci }
                }
                assign[pi] = best
            }
            var sums = [(Double, Double, Double, Int)](repeating: (0, 0, 0, 0), count: k)
            for (pi, p) in lab.enumerated() {
                sums[assign[pi]].0 += p.l; sums[assign[pi]].1 += p.a; sums[assign[pi]].2 += p.b; sums[assign[pi]].3 += 1
            }
            for ci in 0..<k where sums[ci].3 > 0 {
                let n = Double(sums[ci].3)
                centers[ci] = (sums[ci].0 / n, sums[ci].1 / n, sums[ci].2 / n)
            }
        }
        return centers.map { OKLCH(l: $0.l, c: hypot($0.a, $0.b), h: atan2($0.b, $0.a)) }
    }
}
