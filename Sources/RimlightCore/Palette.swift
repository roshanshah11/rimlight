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

public enum Palette {
    public static let fallback = [RGB(0.55, 0.36, 1.0), RGB(0.20, 0.62, 1.0), RGB(1.0, 0.36, 0.72)]

    /// Three glow colors from RGBA8 pixels (any size; pass a downsampled image, ~48×48).
    /// k-means in RGB, clusters ranked by population weighted toward saturated, bright colors,
    /// then pushed bright enough to read as light (dark album art still glows).
    public static func extract(rgba: [UInt8], count k: Int = 3) -> [RGB] {
        var pts: [RGB] = []
        pts.reserveCapacity(rgba.count / 4)
        var i = 0
        while i + 3 < rgba.count {
            if rgba[i + 3] > 128 {
                pts.append(RGB(Double(rgba[i]) / 255, Double(rgba[i + 1]) / 255, Double(rgba[i + 2]) / 255))
            }
            i += 4
        }
        guard pts.count >= 4 else { return fallback }

        // deterministic init: spread across luminance-sorted points
        let clusters = min(6, pts.count)
        let sorted = pts.sorted { ($0.r + $0.g + $0.b) < ($1.r + $1.g + $1.b) }
        var centers = (0..<clusters).map { sorted[($0 * 2 + 1) * sorted.count / (clusters * 2)] }
        var assign = [Int](repeating: 0, count: pts.count)
        for _ in 0..<12 {
            for (pi, p) in pts.enumerated() {
                var best = 0, bd = Double.infinity
                for (ci, c) in centers.enumerated() {
                    let d = p.distance(c)
                    if d < bd { bd = d; best = ci }
                }
                assign[pi] = best
            }
            var sums = [(Double, Double, Double, Int)](repeating: (0, 0, 0, 0), count: clusters)
            for (pi, p) in pts.enumerated() {
                let a = assign[pi]
                sums[a].0 += p.r; sums[a].1 += p.g; sums[a].2 += p.b; sums[a].3 += 1
            }
            for ci in 0..<clusters where sums[ci].3 > 0 {
                let n = Double(sums[ci].3)
                centers[ci] = RGB(sums[ci].0 / n, sums[ci].1 / n, sums[ci].2 / n)
            }
        }
        var pop = [Int](repeating: 0, count: clusters)
        for a in assign { pop[a] += 1 }

        let ranked = (0..<clusters).filter { pop[$0] > 0 }.map { ci -> (RGB, Double) in
            let c = centers[ci], hsv = c.hsv
            let share = Double(pop[ci]) / Double(pts.count)
            let vivid = 0.15 + hsv.s * hsv.s * 1.6 + min(hsv.v, 0.8) * 0.4
            return (c, share.squareRoot() * vivid)
        }.sorted { $0.1 > $1.1 }

        var picked: [RGB] = []
        for (c, _) in ranked where picked.allSatisfy({ $0.distance(c) > 0.35 }) {
            picked.append(c)
            if picked.count == k { break }
        }
        if picked.isEmpty { picked = [ranked[0].0] }

        let lit = picked.map(glowable)
        // grey or single-color art: derive companions by hue rotation so the gradient still moves
        var out = lit
        while out.count < k {
            let base = out[0].hsv
            let shift = out.count == 1 ? 0.08 : -0.08
            let s = base.s < 0.12 ? base.s : max(base.s, 0.55)
            out.append(RGB(h: (base.h + shift + 1).truncatingRemainder(dividingBy: 1), s: s, v: max(base.v, 0.85)))
        }
        return out
    }

    /// Make a color usable as light: lift value, keep hue, mildly boost saturation.
    public static func glowable(_ c: RGB) -> RGB {
        let hsv = c.hsv
        let s = hsv.s < 0.12 ? hsv.s * 0.5 : min(1, hsv.s * 1.15 + 0.05)
        return RGB(h: hsv.h, s: s, v: max(0.85, hsv.v))
    }
}
