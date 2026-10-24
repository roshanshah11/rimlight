import CoreGraphics
import Foundation

/// Screen geometry in points with a top-left origin (y grows downward), the shader's coordinate space.
public struct RimGeometry: Equatable, Sendable {
    public var size: CGSize
    public var cornerRadius: CGFloat
    public var notch: CGRect?          // camera housing, nil on displays without one

    public init(size: CGSize, cornerRadius: CGFloat, notch: CGRect?) {
        self.size = size; self.cornerRadius = cornerRadius; self.notch = notch
    }

    /// Notch rect from NSScreen's frame and its auxiliary top areas (the menu bar space left and right of the
    /// camera). Inputs are AppKit rects (bottom-left origin, global coordinates). Nil if either area is missing.
    public static func notch(screenFrame: CGRect, topLeftArea: CGRect?, topRightArea: CGRect?) -> CGRect? {
        guard let l = topLeftArea, let r = topRightArea, r.minX > l.maxX else { return nil }
        let height = max(l.height, r.height)
        return CGRect(x: l.maxX - screenFrame.minX, y: 0, width: r.minX - l.maxX, height: height)
    }

    /// The four edge strips the overlay draws into (top-left origin). Only these pixels are composited, so a
    /// 120 Hz glow costs a fraction of a full-screen transparent window. The top strip grows to wrap the notch.
    public func strips(band: CGFloat) -> [CGRect] {
        let w = size.width, h = size.height
        let b = min(max(1, band.rounded(.up)), min(w, h) / 2)
        let topH = min(h / 2, b + (notch?.height ?? 0))
        let sideH = max(0, h - topH - b)
        return [
            CGRect(x: 0, y: 0, width: w, height: topH),
            CGRect(x: 0, y: h - b, width: w, height: b),
            CGRect(x: 0, y: topH, width: b, height: sideH),
            CGRect(x: w - b, y: topH, width: b, height: sideH),
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    /// Strip rect (top-left origin, screen-local) → AppKit window frame (bottom-left origin, global).
    public static func windowFrame(strip: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + strip.minX,
               y: screenFrame.maxY - strip.maxY,
               width: strip.width, height: strip.height)
    }
}
