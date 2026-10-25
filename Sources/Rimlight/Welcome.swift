import AppKit
import ServiceManagement

/// Opening at login, through the system's own login items (System Settings › General › Login Items lists it).
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Rimlight: login item \(on ? "register" : "unregister") failed: \(error)")
        }
    }
}

/// The first launch: what Rimlight does, where it lives, and the one permission it needs. "Start" asks macOS for
/// that permission right away, so the prompt shows while the window explains it.
final class Welcome: NSObject {
    private var window: NSWindow?
    private let loginBox = NSButton(checkboxWithTitle: "Open Rimlight when I log in", target: nil, action: nil)
    var onDone: (() -> Void)?

    /// The window's content, also drawn offscreen by `rimlight debug-welcome`.
    func makeView() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let title = NSTextField(labelWithString: "Rimlight lights your screen to the music")
        title.font = .systemFont(ofSize: 19, weight: .semibold)

        let body = Self.paragraph(
            "Play music in Spotify, Apple Music or any other app, and the edges of your screen light up with it: a "
            + "soft wash in slow songs, pulses on the beat, a hit when the drop lands. In Spotify and Apple Music the "
            + "colors come from the album art.")
        let permission = Self.paragraph(
            "macOS will ask to let Rimlight hear your Mac's audio. Allow it so the light can follow the beat. Rimlight "
            + "never records, saves or sends what it hears.")
        let menu = NSTextField(labelWithAttributedString: Self.menuHint())
        menu.lineBreakMode = .byWordWrapping
        menu.preferredMaxLayoutWidth = 380

        loginBox.state = .on
        let start = NSButton(title: "Start", target: self, action: #selector(begin))
        start.keyEquivalent = "\r"
        let buttons = NSStackView(views: [loginBox, NSView(), start])
        buttons.orientation = .horizontal
        buttons.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let text = NSStackView(views: [title, body, permission, menu])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 10
        text.setCustomSpacing(14, after: title)

        let stack = NSStackView(views: [icon, text, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 30, bottom: 22, right: 30)
        return stack
    }

    func show() {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 420), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Welcome to Rimlight"
        w.isReleasedWhenClosed = false
        w.contentView = makeView()
        w.setContentSize(w.contentView!.fittingSize)
        w.center()
        NotificationCenter.default.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: w)
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func begin() {
        LoginItem.set(loginBox.state == .on)
        AudioTap.requestPermission()
        window?.close()
    }

    @objc private func closed() {
        window = nil
        onDone?()
        onDone = nil
    }

    private static func paragraph(_ s: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = .systemFont(ofSize: 13)
        f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = 380
        return f
    }

    /// "Click [the rays icon] in the menu bar for ..." with the menu bar icon itself in the line.
    private static func menuHint() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 13)
        let s = NSMutableAttributedString(string: "Click ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        if let img = NSImage(systemSymbolName: "rays", accessibilityDescription: "Rimlight")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            let a = NSTextAttachment()
            a.image = img
            a.bounds = CGRect(x: 0, y: -2, width: img.size.width, height: img.size.height)
            s.append(NSAttributedString(attachment: a))
        }
        s.append(NSAttributedString(string: " in the menu bar for brightness, timing and the other settings.",
                                    attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }
}
