// make-icon.swift: draws Rimlight's app icon (a dark screen whose edge glows, the app's own look) and writes
// Resources/AppIcon.icns. Run from the repo root: swift scripts/make-icon.swift
import AppKit
import CoreImage

let side = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)    // Apple's macOS icon grid: 824 pt tile, 100 pt margin
let radius: CGFloat = 185
let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.55, 0.36, 1.0), (0.18, 0.61, 1.0), (1.0, 0.36, 0.72), (0.55, 0.36, 1.0)]

func context() -> CGContext {
    CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Colors going around the center (CoreGraphics has no conic gradient in Swift), whitened toward the core.
func conic(whiten: CGFloat) -> CGImage {
    var px = [UInt8](repeating: 255, count: side * side * 4)
    for y in 0..<side {
        for x in 0..<side {
            let a = atan2(Double(y - side / 2), Double(x - side / 2)) + .pi * 1.25
            let u = (a / (2 * .pi)).truncatingRemainder(dividingBy: 1) * Double(colors.count - 1)
            let i = min(Int(u), colors.count - 2), f = CGFloat(u - Double(i))
            let (r0, g0, b0) = colors[i], (r1, g1, b1) = colors[i + 1]
            let rgb = [r0 + (r1 - r0) * f, g0 + (g1 - g0) * f, b0 + (b1 - b0) * f].map { $0 + (1 - $0) * whiten }
            let o = (y * side + x) * 4
            px[o] = UInt8(rgb[0] * 255); px[o + 1] = UInt8(rgb[1] * 255); px[o + 2] = UInt8(rgb[2] * 255)
        }
    }
    let c = context()
    px.withUnsafeBytes { b in c.data!.copyMemory(from: b.baseAddress!, byteCount: b.count) }
    return c.makeImage()!
}

/// The rim: the tile's edge, inset, stroked with a conic gradient that goes around it.
func rim(width: CGFloat, inset: CGFloat, whiten: CGFloat) -> CGImage {
    let c = context()
    let path = CGPath(roundedRect: tile.insetBy(dx: inset, dy: inset), cornerWidth: radius - inset, cornerHeight: radius - inset, transform: nil)
    c.addPath(path)
    c.setLineWidth(width)
    c.replacePathWithStrokedPath()
    c.clip()
    c.draw(conic(whiten: whiten), in: CGRect(x: 0, y: 0, width: side, height: side))
    return c.makeImage()!
}

let ci = CIContext()
func blur(_ img: CGImage, _ r: Double) -> CIImage {
    CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: r).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
}

let out = context()
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
// the screen: near black, a touch lighter toward the middle
out.saveGState()
out.addPath(tilePath)
out.clip()
let bg = CGGradient(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    colorComponents: [0.09, 0.08, 0.15, 1, 0.025, 0.025, 0.05, 1], locations: [0, 1], count: 2)!
out.drawRadialGradient(bg, startCenter: CGPoint(x: 512, y: 540), startRadius: 0, endCenter: CGPoint(x: 512, y: 512),
                       endRadius: 560, options: .drawsAfterEndLocation)
// the light: a wide bloom into the screen, a tighter halo, and a bright core line on the edge
let bloom = blur(rim(width: 60, inset: 34, whiten: 0), 46)
let halo = blur(rim(width: 26, inset: 30, whiten: 0.1), 12)
let core = blur(rim(width: 9, inset: 30, whiten: 0.55), 1.2)
var light = bloom.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.9)])
light = halo.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: light])
light = core.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: light])
let lit = ci.createCGImage(light, from: CGRect(x: 0, y: 0, width: side, height: side))!
out.setBlendMode(.screen)
out.draw(lit, in: CGRect(x: 0, y: 0, width: side, height: side))
out.restoreGState()
// a hairline so the tile holds its shape on a dark Dock
out.addPath(tilePath)
out.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
out.setLineWidth(2)
out.strokePath()
let master = out.makeImage()!

// the iconset: every size macOS asks for, then iconutil
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
func write(_ px: Int, _ name: String) throws {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
}
for s in [16, 32, 128, 256, 512] {
    try write(s, "icon_\(s)x\(s).png")
    try write(s * 2, "icon_\(s)x\(s)@2x.png")
}
try NSBitmapImageRep(cgImage: master).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir.path, "-o", "Resources/AppIcon.icns"]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
