import AppKit
import Metal
import QuartzCore
import RimlightCore

/// Everything one frame of glow needs. Colors are linear sRGB; positions are screen points, top-left origin.
struct GlowFrame {
    var geometry: RimGeometry
    var scale: Float               // pixels per point
    var thickness: Float
    var reach: Float               // halo spread, points
    var brightness: Float          // 0...1
    var fade: Float                // 0...1, idle fade
    var pulse: Float               // 0...1 beat envelope, already scaled by reactivity
    var energy: Float              // 0...1
    var time: Float                // seconds, drives the slow color drift
    var headroom: Float            // EDR headroom of the screen; 1 = no HDR
    var colors: [SIMD3<Float>]     // three
}

/// One Metal pipeline shared by every strip on every screen. The fragment shader draws a signed-distance rim: a
/// bright core line on the screen edge (wrapping the notch) and an exponential haze that fades inward.
final class GlowRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let pipeline8: MTLRenderPipelineState   // 8-bit sRGB target for debug renders

    struct Uniforms {
        var screen: SIMD4<Float>   // w, h, corner radius, scale
        var strip: SIMD4<Float>    // x, y, w, h
        var notch: SIMD4<Float>    // x, y, w, h (w = 0: none)
        var shape: SIMD4<Float>    // thickness, reach, brightness, fade
        var motion: SIMD4<Float>   // pulse, energy, time, headroom
        var c0: SIMD4<Float>, c1: SIMD4<Float>, c2: SIMD4<Float>
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
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = false
    }

    private func uniforms(_ f: GlowFrame, strip: CGRect) -> Uniforms {
        let g = f.geometry
        let n = g.notch ?? .zero
        let c = (0..<3).map { i -> SIMD4<Float> in
            let v = i < f.colors.count ? f.colors[i] : SIMD3<Float>(1, 1, 1)
            return SIMD4(v, 1)
        }
        return Uniforms(
            screen: SIMD4(Float(g.size.width), Float(g.size.height), Float(g.cornerRadius), f.scale),
            strip: SIMD4(Float(strip.minX), Float(strip.minY), Float(strip.width), Float(strip.height)),
            notch: SIMD4(Float(n.minX), Float(n.minY), Float(n.width), Float(n.height)),
            shape: SIMD4(f.thickness, f.reach, f.brightness, f.fade),
            motion: SIMD4(f.pulse, f.energy, f.time, f.headroom),
            c0: c[0], c1: c[1], c2: c[2])
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
    func draw(_ frame: GlowFrame, into layers: [(CAMetalLayer, CGRect)]) {
        guard let cb = queue.makeCommandBuffer() else { return }
        for (layer, strip) in layers {
            guard let drawable = layer.nextDrawable() else { continue }
            encode(cb, target: drawable.texture, pipeline: pipeline, frame: frame, strip: strip)
            cb.present(drawable)
        }
        cb.commit()
    }

    /// Render the whole screen offscreen over a flat "desktop" color and return RGBA8 pixels (sRGB, row-major).
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
        // composite premultiplied glow over the background (in sRGB space; good enough for a preview)
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
        float4 shape;    // thickness, reach, brightness, fade
        float4 motion;   // pulse, energy, time, headroom
        float4 c0, c1, c2;
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

    // haze at `e` points from a lit edge: exponential, reaching exactly zero at `r`
    static float haze(float e, float r) {
        e = max(e, 0.0);
        return exp(-3.0 * e / r) * (1.0 - smoothstep(0.55 * r, r, e));
    }

    fragment float4 rim_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 size = u.screen.xy;
        float2 p = u.strip.xy + in.pos.xy / u.screen.w;

        // distance to the lit boundary: the screen's rounded rect minus the notch (whose top runs off-screen,
        // so only its bottom corners round)
        float d = sdRoundBox(p, size * 0.5, size * 0.5, u.screen.z);
        float dn = 1e5;
        if (u.notch.z > 0.0) {
            float2 nc = float2(u.notch.x + u.notch.z * 0.5, (u.notch.y + u.notch.w - 40.0) * 0.5);
            float2 nh = float2(u.notch.z * 0.5, (u.notch.w + 40.0) * 0.5);
            dn = sdRoundBox(p, nc, nh, min(9.0, u.notch.z * 0.25));
            d = max(d, -dn);
        }
        float e = -d;                       // points inward from the edge
        if (e < 0.0) return float4(0.0);

        float th = u.shape.x, reach = u.shape.y, bright = u.shape.z, fade = u.shape.w;
        float pulse = u.motion.x, energy = u.motion.y, t = u.motion.z, headroom = u.motion.w;

        float core = 1.0 - smoothstep(th * 0.55, th * 1.15, e);
        // the haze reaches further in on a beat, and always reaches zero inside the strip band (1.6 x glow)
        // each edge (and the notch) casts its own haze, combined like overlapping lights, so corners stay
        // smooth instead of creasing along the diagonal
        float r = max(reach * (1.0 + 0.5 * pulse), 1.0);
        float dark = (1.0 - haze(p.y, r)) * (1.0 - haze(size.y - p.y, r))
                   * (1.0 - haze(p.x, r)) * (1.0 - haze(size.x - p.x, r)) * (1.0 - haze(dn, r));
        float halo = (1.0 - dark) * (1.0 - core);

        float coreAmt = 0.80 + 0.15 * energy + 0.35 * pulse;
        float haloAmt = 0.28 + 0.15 * energy + 0.55 * pulse;
        float boost = headroom > 1.0 ? min(headroom, 1.0 + 1.6 * pulse) : 1.0;

        // three colors around the rim, drifting slowly
        float a = atan2(p.y - size.y * 0.5, p.x - size.x * 0.5) / (2.0 * M_PI_F) + 0.5;
        float f = fract(a + t * 0.015) * 3.0;
        int i = int(floor(f));
        float k = smoothstep(0.0, 1.0, fract(f));
        float3 cols[3] = { u.c0.rgb, u.c1.rgb, u.c2.rgb };
        float3 col = mix(cols[i % 3], cols[(i + 1) % 3], k);
        float3 coreCol = mix(col, float3(1.0), 0.18 + 0.25 * pulse);   // the line runs hotter than the haze

        float lc = core * coreAmt, lh = halo * haloAmt;
        float alpha = saturate(lc + lh) * bright * fade;
        float3 rgb = (coreCol * lc * boost + col * lh) * bright * fade;
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
