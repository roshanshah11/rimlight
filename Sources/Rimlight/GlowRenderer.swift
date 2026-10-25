import AppKit
import Metal
import QuartzCore
import RimlightCore

/// Everything one frame needs. Colors are linear sRGB; positions are screen points, top-left origin.
struct GlowFrame {
    var geometry: RimGeometry
    var scale: Float               // pixels per point
    var edge: Float                // width of the bright edge source, points
    var reach: Float               // how far the light blooms in, points
    var brightness: Float          // 0...1
    var fade: Float                // 0...1, idle fade
    var headroom: Float            // EDR headroom of the screen; 1 = no HDR
    var light: LightState
    var target: Double = 0         // when the display link expects this frame on screen (host seconds); 0 = untracked
}

/// How late frames really reach the screen against the display link's target, from Metal's presented times: the
/// compositor can hold a window's frame a refresh or more. Kept per screen, as a slow average.
final class PresentLag: @unchecked Sendable {
    private let lock = NSLock()
    private var mean: Double?
    private var samples: [Double] = []
    private(set) var count = 0

    func add(_ lag: Double) {
        guard lag > -0.05, lag < 0.2 else { return }   // a dropped or stale frame
        lock.lock(); defer { lock.unlock() }
        mean = mean.map { $0 + (lag - $0) * 0.02 } ?? lag
        samples.append(lag)
        if samples.count > 600 { samples.removeFirst(samples.count - 600) }
        count += 1
    }

    /// The average lag once a second's worth of frames is in, seconds.
    var value: Double? { lock.lock(); defer { lock.unlock() }; return count >= 60 ? mean : nil }

    /// Median and the 10th to 90th percentile of the last few seconds, seconds.
    var spread: (median: Double, p10: Double, p90: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard samples.count >= 30 else { return nil }
        let s = samples.sorted()
        return (s[s.count / 2], s[s.count / 10], s[s.count * 9 / 10])
    }
}

/// One Metal pipeline shared by every strip on every screen. The rim is treated like a ring of stage lights:
/// a mirrored row of fixtures, a chase, a wash and white hits, each lit along the edge and blooming inward.
/// Each edge (and the notch) casts its own bloom, so corners blend instead of creasing. The output is partly
/// additive (alpha below the color), so it reads as light over the screen rather than paint on it.
final class GlowRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let pipeline8: MTLRenderPipelineState   // 8-bit sRGB target for previews

    struct Uniforms {
        var screen: SIMD4<Float>   // w, h, corner radius, scale
        var strip: SIMD4<Float>    // x, y, w, h
        var notch: SIMD4<Float>    // x, y, w, h (w = 0: none)
        var shape: SIMD4<Float>    // edge, reach, brightness, fade
        var look0: SIMD4<Float>    // master, bloom, pulse, flash
        var look1: SIMD4<Float>    // wash level, fixtures, fixture level, alternate
        var look2: SIMD4<Float>    // chase position, chase width, chase level, headroom
        var wash: SIMD4<Float>
        var colA: SIMD4<Float>
        var colB: SIMD4<Float>
        var chase: SIMD4<Float>
    }

    init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else {
            throw NSError(domain: "Rimlight", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Metal device"])
        }
        device = d
        queue = q
        let lib = try d.makeLibrary(source: Self.source, options: nil)
        func make(_ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let p = MTLRenderPipelineDescriptor()
            p.vertexFunction = lib.makeFunction(name: "rim_vertex")
            p.fragmentFunction = lib.makeFunction(name: "rim_fragment")
            p.colorAttachments[0].pixelFormat = format
            return try d.makeRenderPipelineState(descriptor: p)
        }
        pipeline = try make(.rgba16Float)
        pipeline8 = try make(.rgba8Unorm_srgb)
    }

    static func configure(_ layer: CAMetalLayer, device: MTLDevice, hdr: Bool) {
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.wantsExtendedDynamicRangeContent = hdr
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2   // one on screen, one being drawn: the shader is tiny
    }

    private func uniforms(_ f: GlowFrame, strip: CGRect) -> Uniforms {
        let g = f.geometry, n = g.notch ?? .zero, l = f.light
        return Uniforms(
            screen: SIMD4(Float(g.size.width), Float(g.size.height), Float(g.cornerRadius), f.scale),
            strip: SIMD4(Float(strip.minX), Float(strip.minY), Float(strip.width), Float(strip.height)),
            notch: SIMD4(Float(n.minX), Float(n.minY), Float(n.width), Float(n.height)),
            shape: SIMD4(f.edge, f.reach, f.brightness, f.fade),
            look0: SIMD4(l.master, l.bloom, l.pulse, l.flash),
            look1: SIMD4(l.washLevel, l.fixtures, l.fixtureLevel, l.alternate),
            look2: SIMD4(l.chasePos, l.chaseWidth, l.chaseLevel, f.headroom),
            wash: SIMD4(l.wash, 1), colA: SIMD4(l.colorA, 1), colB: SIMD4(l.colorB, 1), chase: SIMD4(l.chaseColor, 1))
    }

    private func encode(_ cb: MTLCommandBuffer, target: MTLTexture, pipeline: MTLRenderPipelineState,
                        frame: GlowFrame, strip: CGRect) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms(frame, strip: strip)
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Draw one frame into each strip's layer.
    func draw(_ frame: GlowFrame, into layers: [(CAMetalLayer, CGRect)], lag: PresentLag? = nil) {
        guard let cb = queue.makeCommandBuffer() else { return }
        for (i, (layer, strip)) in layers.enumerated() {
            guard let drawable = layer.nextDrawable() else { continue }
            encode(cb, target: drawable.texture, pipeline: pipeline, frame: frame, strip: strip)
            if i == 0, let lag, frame.target > 0 {
                let target = frame.target
                drawable.addPresentedHandler { d in if d.presentedTime > 0 { lag.add(d.presentedTime - target) } }
            }
            cb.present(drawable)
        }
        cb.commit()
    }

    /// Render the whole screen offscreen over `backdrop` (RGBA8, the screen's pixel size) into `out`, for videos.
    func renderPixels(_ frame: GlowFrame, backdrop: [UInt8], into out: inout [UInt8]) {
        let w = Int(frame.geometry.size.width * CGFloat(frame.scale))
        let h = Int(frame.geometry.size.height * CGFloat(frame.scale))
        if target == nil || target!.width != w || target!.height != h {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = .shared
            target = device.makeTexture(descriptor: td)
        }
        guard let tex = target, let cb = queue.makeCommandBuffer() else { return }
        var f = frame
        f.headroom = 1
        encode(cb, target: tex, pipeline: pipeline8, frame: f, strip: CGRect(origin: .zero, size: frame.geometry.size))
        cb.commit()
        cb.waitUntilCompleted()
        if out.count != w * h * 4 { out = [UInt8](repeating: 0, count: w * h * 4) }
        out.withUnsafeMutableBytes { tex.getBytes($0.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        // premultiplied light over the backdrop
        backdrop.withUnsafeBufferPointer { bg in
            out.withUnsafeMutableBufferPointer { px in
                var i = 0
                while i < px.count {
                    let a = Int(px[i + 3])
                    for c in 0..<3 { px[i + c] = UInt8(min(255, Int(px[i + c]) + Int(bg[i + c]) * (255 - a) / 255)) }
                    px[i + 3] = 255
                    i += 4
                }
            }
        }
    }
    private var target: MTLTexture?

    /// Render the whole screen offscreen over a flat "desktop" color, for previews.
    func renderImage(_ frame: GlowFrame, background: RGB) -> CGImage? {
        let w = Int(frame.geometry.size.width * CGFloat(frame.scale))
        let h = Int(frame.geometry.size.height * CGFloat(frame.scale))
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer() else { return nil }
        var f = frame
        f.headroom = 1
        encode(cb, target: tex, pipeline: pipeline8, frame: f, strip: CGRect(origin: .zero, size: frame.geometry.size))
        cb.commit()
        cb.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let bg = [background.r, background.g, background.b].map { $0 * 255 }
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            for c in 0..<3 { px[i + c] = UInt8(min(255, Double(px[i + c]) + bg[c] * (1 - a))) }
            px[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 screen;   // w, h, corner radius, scale
        float4 strip;    // x, y, w, h (points, top-left origin)
        float4 notch;    // x, y, w, h
        float4 shape;    // edge, reach, brightness, fade
        float4 look0;    // master, bloom, pulse, flash
        float4 look1;    // wash level, fixtures, fixture level, alternate
        float4 look2;    // chase position, chase width, chase level, headroom
        float4 wash, colA, colB, chase;
    };

    struct VOut { float4 pos [[position]]; };

    vertex VOut rim_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    static float sdRoundBox(float2 p, float2 c, float2 halfSize, float r) {
        float2 q = abs(p - c) - halfSize + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    // light from an edge source `e` points away: a bright, soft source at the edge, a bloom, and a faint long
    // spill that carries the color well into the screen (so it reads as light on the screen, not a frame
    // around it). Everything reaches zero by 1.85 r, inside the strip band (2.3 x glow).
    static float falloff(float e, float edge, float r) {
        e = max(e, 0.0);
        float source = exp(-e / max(edge, 0.5));
        float bloom = exp(-2.6 * e / r) * (1.0 - smoothstep(0.45 * r, r, e));
        float spill = exp(-e / (0.8 * r)) * (1.0 - smoothstep(1.1 * r, 1.85 * r, e));
        return 0.3 * source + 0.85 * bloom + 0.22 * spill;
    }

    // the show at rim position u (0...1, starting bottom center, going around); both halves mirror
    static float3 lightAt(float u, constant Uniforms& U) {
        float m = u < 0.5 ? u * 2.0 : (1.0 - u) * 2.0;     // 0 bottom center, 1 top center
        float3 col = U.wash.rgb * U.look1.x;

        // fixtures: wide pools of light in two alternating colors that blend into each other (no dark gaps,
        // which read as a dashed border); the alternate flag swaps the colors on the beat
        float n = max(U.look1.y, 1.0);
        float x = m * n + U.look1.w;
        float tri = abs(fract(x * 0.5) * 2.0 - 1.0);                  // 0 at even fixture centers, 1 at odd
        float blend = smoothstep(0.38, 0.62, tri);                     // pure pools, short soft seams
        float pool = 0.7 + 0.3 * (0.5 + 0.5 * cos(x * 6.2831853));     // brightest at each fixture's center
        col += mix(U.colA.rgb, U.colB.rgb, blend) * (U.look1.z * pool);

        float d = m - U.look2.x;
        float w = max(U.look2.y, 0.01);
        col += U.chase.rgb * (U.look2.z * exp(-d * d / (w * w)));

        float master = U.look0.x * (0.7 + 0.6 * U.look0.z);
        return col * master + float3(U.look0.w);
    }

    fragment float4 rim_fragment(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
        float W = U.screen.x, H = U.screen.y;
        float2 p = U.strip.xy + in.pos.xy / U.screen.w;

        // nothing outside the screen's rounded corners or inside the camera housing
        float d = sdRoundBox(p, float2(W, H) * 0.5, float2(W, H) * 0.5, U.screen.z);
        float dn = 1e5;
        if (U.notch.z > 0.0) {
            float2 nc = float2(U.notch.x + U.notch.z * 0.5, (U.notch.y + U.notch.w - 40.0) * 0.5);
            float2 nh = float2(U.notch.z * 0.5, (U.notch.w + 40.0) * 0.5);
            dn = sdRoundBox(p, nc, nh, min(9.0, U.notch.z * 0.25));
        }
        if (d > 0.0 || dn < 0.0) return float4(0.0);

        float edge = U.shape.x, reach = U.shape.y, bright = U.shape.z, fade = U.shape.w;
        float r = max(reach * (0.55 + 0.45 * U.look0.y + 0.2 * U.look0.z), 1.0);
        float perim = 2.0 * (W + H);
        float x = clamp(p.x, 0.0, W), y = clamp(p.y, 0.0, H);

        // where each edge's nearest point sits on the rim (bottom center = 0, then right, top, left)
        float uBottom = (x >= W * 0.5 ? x - W * 0.5 : 1.5 * W + 2.0 * H + x) / perim;
        float uRight = (W * 0.5 + (H - y)) / perim;
        float uTop = (W * 0.5 + H + (W - x)) / perim;
        float uLeft = (1.5 * W + H + y) / perim;

        float3 light = lightAt(uBottom, U) * falloff(H - p.y, edge, r)
                     + lightAt(uRight, U) * falloff(W - p.x, edge, r)
                     + lightAt(uTop, U) * falloff(p.y, edge, r)
                     + lightAt(uLeft, U) * falloff(p.x, edge, r);
        if (U.notch.z > 0.0) light += lightAt(uTop, U) * falloff(dn, edge, r);

        // HDR screens: hits and pulses go brighter than white
        float headroom = U.look2.w;
        float boost = headroom > 1.0 ? 1.0 + (headroom - 1.0) * saturate(U.look0.w + 0.5 * U.look0.z) : 1.0;
        float3 rgb = light * bright * fade * boost;
        float alpha = saturate(max(rgb.r, max(rgb.g, rgb.b)) * 0.6);
        return float4(rgb, alpha);
    }
    """
}

extension RGB {
    var linearSIMD: SIMD3<Float> {
        let l = linear
        return SIMD3(Float(l.0), Float(l.1), Float(l.2))
    }
}
