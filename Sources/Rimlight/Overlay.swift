import AppKit
import QuartzCore
import RimlightCore

/// A borderless, transparent window over one edge strip. Clicks pass through; it sits above full-screen apps,
/// the menu bar and the Dock, on every Space.
final class StripWindow: NSWindow {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // the top strip covers the menu bar; don't let AppKit push it down
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The glow on one screen: a window and Metal layer per edge strip, driven by the screen's own display link.
final class ScreenOverlay: NSObject {
    let screen: NSScreen
    let name: String
    let builtIn: Bool
    /// The iMac's virtual display: its picture and sound reach the iMac together in one stream, so its light is
    /// timed to the moment the sound was played here, not to this Mac's speakers.
    let streamed: Bool
    let geometry: RimGeometry
    /// Called per refresh with the time this frame reaches the screen and how long it stays there.
    var onFrame: ((ScreenOverlay, Double, Double) -> Void)?
    private(set) var running = false

    private let renderer: GlowRenderer
    private var strips: [(window: StripWindow, layer: CAMetalLayer, rect: CGRect)] = []
    private var link: CADisplayLink?

    /// The iMac stream (~/Projects/imac) is set up on this Mac: its sender keeps a folder in Application Support.
    static let streamSetUp = FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/imac-display").path)

    static func isStreamed(_ screen: NSScreen) -> Bool {
        streamSetUp && CGDisplayIsBuiltin(displayID(screen)) == 0 && screen.localizedName.lowercased().contains("imac")
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func renderScale(_ s: RimSettings, lowMemory: Bool) -> Double { lowMemory ? 0.5 : s.renderScale }
    private(set) var renderScale: Float = 1

    init(screen: NSScreen, settings: RimSettings, renderer: GlowRenderer, lowMemory: Bool = false) {
        self.screen = screen
        self.renderer = renderer
        name = screen.localizedName
        builtIn = CGDisplayIsBuiltin(Self.displayID(screen)) != 0
        streamed = Self.isStreamed(screen)

        let size = screen.frame.size
        var notch: CGRect?
        if settings.wrapNotch, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, r.minX > l.maxX {
            // the camera housing is centered; its height is the top safe-area inset
            let w = r.minX - l.maxX
            let h = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : max(l.height, r.height)
            notch = CGRect(x: (size.width - w) / 2, y: 0, width: w, height: h)
        }
        geometry = RimGeometry(size: size, cornerRadius: builtIn ? 10 : 0, notch: notch)
        super.init()

        // The glow is soft, so it's drawn at one pixel per point and scaled up: a quarter of the pixels on a Retina
        // screen, and of the memory (each strip keeps two drawables; under memory pressure, half a pixel per point)
        let scale = min(screen.backingScaleFactor, CGFloat(Self.renderScale(settings, lowMemory: lowMemory)))
        renderScale = Float(scale)
        for rect in geometry.strips(band: CGFloat(settings.band)) {
            let w = StripWindow(frame: RimGeometry.windowFrame(strip: rect, screenFrame: screen.frame))
            let layer = CAMetalLayer()
            GlowRenderer.configure(layer, device: renderer.device, hdr: settings.hdr && !streamed)
            layer.contentsScale = scale
            layer.drawableSize = CGSize(width: rect.width * scale, height: rect.height * scale)
            let view = NSView(frame: CGRect(origin: .zero, size: rect.size))
            view.layer = layer
            view.wantsLayer = true
            w.contentView = view
            w.setFrame(RimGeometry.windowFrame(strip: rect, screenFrame: screen.frame), display: false)
            strips.append((w, layer, rect))
        }

        let l = screen.displayLink(target: self, selector: #selector(tick(_:)))
        if streamed {
            let fps = Float(settings.streamedFPS)
            l.preferredFrameRateRange = CAFrameRateRange(minimum: min(10, fps), maximum: fps, preferred: fps)
        }
        l.isPaused = true
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ link: CADisplayLink) {
        let period = link.targetTimestamp - link.timestamp
        onFrame?(self, link.targetTimestamp, period > 0 ? period : 1.0 / 60)
    }

    func start() {
        guard !running else { return }
        running = true
        let k = CGFloat(renderScale)
        for s in strips {
            s.layer.drawableSize = CGSize(width: s.rect.width * k, height: s.rect.height * k)
            s.window.orderFrontRegardless()
        }
        link?.isPaused = false
    }

    func stop() {
        guard running else { return }
        running = false
        link?.isPaused = true
        for s in strips {
            s.window.orderOut(nil)
            s.layer.drawableSize = CGSize(width: 1, height: 1)   // let the idle strips' drawables go
        }
    }

    func invalidate() {
        stop()
        link?.invalidate()
        link = nil
        for s in strips { s.window.close() }
        strips = []
    }

    /// How late this screen's frames land against the display link's target.
    let presentLag = PresentLag()

    func render(_ frame: GlowFrame) {
        renderer.draw(frame, into: strips.map { ($0.layer, $0.rect) }, lag: presentLag)
    }

    var scale: Float { renderScale }

    /// Current EDR headroom: above 1 only on HDR-capable screens (the XDR panel), and only while EDR is active.
    var headroom: Float { Float(screen.maximumExtendedDynamicRangeColorComponentValue) }
}
