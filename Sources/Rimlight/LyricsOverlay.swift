import AppKit

/// The current lyric line in small white text near the bottom of one screen, with the next line dimmer below.
/// Hidden during instrumental parts and whenever the glow is idle.
final class LyricsOverlay {
    private let window: StripWindow
    private let current = NSTextField(labelWithString: "")
    private let upcoming = NSTextField(labelWithString: "")
    private var shownOn: NSScreen?
    private var visible = false

    init() {
        window = StripWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 64))
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = .zero
        for (f, size, alpha) in [(current, 17.0, 0.95), (upcoming, 13.0, 0.5)] {
            f.font = .systemFont(ofSize: size, weight: f === current ? .semibold : .regular)
            f.textColor = NSColor.white.withAlphaComponent(alpha)
            f.alignment = .center
            f.lineBreakMode = .byTruncatingTail
            f.shadow = shadow
            f.translatesAutoresizingMaskIntoConstraints = false
        }
        let stack = NSStackView(views: [current, upcoming])
        stack.orientation = .vertical
        stack.spacing = 3
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(frame: window.contentLayoutRect)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            current.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor),
            upcoming.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor),
        ])
        window.contentView = root
    }

    func show(line: String?, next: String?, on screen: NSScreen?, bottomInset: CGFloat) {
        guard let line, let screen else {
            if visible { window.orderOut(nil); visible = false }
            return
        }
        if current.stringValue != line { current.stringValue = line }
        let n = next ?? ""
        if upcoming.stringValue != n { upcoming.stringValue = n }
        if shownOn != screen || !visible {
            let f = screen.frame
            let w = min(900, f.width - 2 * bottomInset)
            // sit just inside the glow band, above the Dock area
            window.setFrame(CGRect(x: f.midX - w / 2, y: f.minY + max(24, bottomInset * 0.6), width: w, height: 64),
                            display: true)
            shownOn = screen
        }
        if !visible { window.orderFrontRegardless(); visible = true }
    }
}
