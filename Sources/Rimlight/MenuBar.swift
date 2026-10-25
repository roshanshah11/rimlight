import AppKit
import RimlightCore

/// The menu bar light: the song and the look, the three things worth reaching for (on/off, brightness, sync), and
/// everything else under More. `rimlight status` keeps the beat source and timing details.
final class MenuBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let engine: Engine

    init(engine: Engine) {
        self.engine = engine
        super.init()
        let img = NSImage(systemSymbolName: "rays", accessibilityDescription: "Rimlight")
        img?.isTemplate = true
        item.button?.image = img
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = engine.settings

        menu.addItem(info(engine.nowPlayingLine))
        if s.enabled, engine.songLine != nil { menu.addItem(info(lookSummary(s))) }
        if s.enabled, engine.audioBlocked {
            menu.addItem(info("Rimlight hears only silence. If music is playing, macOS isn't letting it listen."))
            menu.addItem(ActionItem(title: "Allow in System Settings…") {
                // Privacy & Security › Screen & System Audio Recording › System Audio Recording Only
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
            })
        }
        menu.addItem(.separator())

        menu.addItem(toggle("Light show", s.enabled) { $0.enabled.toggle() })
        menu.addItem(slider("Brightness", s.brightness * 100, 0...100, unit: "%") { s, v in s.brightness = v / 100 })
        menu.addItem(slider("Sync (if the light is early or late)", s.syncOffsetMs, -300...300, unit: " ms") { s, v in
            s.syncOffsetMs = v
        })
        if engine.calibration == nil {
            menu.addItem(ActionItem(title: "Calibrate timing for these speakers or headphones…") { [weak self] in
                self?.engine.startAutoCalibration()
            })
        } else {
            menu.addItem(ActionItem(title: "Stop calibrating") { [weak self] in self?.engine.calibration?.cancel() })
        }
        menu.addItem(.separator())

        let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        more.submenu = moreMenu(s)
        menu.addItem(more)
        menu.addItem(ActionItem(title: "About Rimlight") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [
                .credits: NSAttributedString(string: "Light from the music, around the edges of your screen.",
                                             attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
            ])
        })
        menu.addItem(NSMenuItem(title: "Quit Rimlight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// "Hook · rap · 155 BPM", "Ambiance · 70 BPM", or the calm style's name.
    private func lookSummary(_ s: RimSettings) -> String {
        if s.motion == .steady { return "Steady" }
        let st = engine.style
        var parts = [st.name(engine.section)]
        if st != .ambient { parts.append(st.label) }
        if let bpm = engine.tempo { parts.append(String(format: "%.0f BPM", bpm)) }
        return parts.joined(separator: " · ")
    }

    private func moreMenu(_ s: RimSettings) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        for (mode, label) in [(Motion.beat, "Light show: club, rap or ambiance, picked per song"), (.flow, "Ambiance: a wash that breathes, no hits"),
                              (.steady, "Steady: no movement")] {
            m.addItem(toggle(label, s.motion == mode) { $0.motion = mode })
        }
        m.addItem(.separator())
        m.addItem(slider("Glow reach", s.glow, 20...200, unit: " pt") { s, v in s.glow = v })
        m.addItem(slider("Beat strength", s.reactivity * 100, 0...100, unit: "%") { s, v in s.reactivity = v / 100 })
        m.addItem(slider("Edge", s.thickness, 1...12, unit: " pt") { s, v in s.thickness = v })
        m.addItem(.separator())
        m.addItem(toggle("Colors from album art", s.colorSource == .album) {
            $0.colorSource = $0.colorSource == .album ? .custom : .album
        })
        m.addItem(toggle("White hits on drops", s.flashes) { $0.flashes.toggle() })
        m.addItem(toggle("Fade out when music stops", s.idleWhenPaused) { $0.idleWhenPaused.toggle() })
        // the rest only where they mean something on this Mac
        if ScreenOverlay.streamSetUp {
            m.addItem(toggle("Only the iMac while it's streaming", s.iMacOnly) { $0.iMacOnly.toggle() })
        }
        if NSScreen.screens.contains(where: { $0.safeAreaInsets.top > 0 }) {
            m.addItem(toggle("Wrap the notch", s.wrapNotch) { $0.wrapNotch.toggle() })
        }
        if NSScreen.screens.contains(where: { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }) {
            m.addItem(toggle("Brighter flashes on HDR screens", s.hdr) { $0.hdr.toggle() })
        }
        if engine.hasLyricsSource || s.lyrics {
            m.addItem(toggle("Lyrics line on the screen", s.lyrics) { $0.lyrics.toggle() })
        }
        m.addItem(.separator())
        let login = ActionItem(title: "Open at login") { [weak self] in
            LoginItem.set(!LoginItem.enabled)
            self?.engine.onChange?()
        }
        login.state = LoginItem.enabled ? .on : .off
        m.addItem(login)
        return m
    }

    private func info(_ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ edit: @escaping (inout RimSettings) -> Void) -> NSMenuItem {
        let i = ActionItem(title: title) { [weak self] in self?.engine.change(edit) }
        i.state = on ? .on : .off
        return i
    }

    private func slider(_ title: String, _ value: Double, _ range: ClosedRange<Double>, unit: String,
                        _ edit: @escaping (inout RimSettings, Double) -> Void) -> NSMenuItem {
        let i = NSMenuItem()
        i.view = SliderRow(title: title, value: value, range: range, unit: unit) { [weak self] v in
            self?.engine.change { edit(&$0, v) }
        }
        return i
    }
}

private final class ActionItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

private final class SliderRow: NSView {
    private let label = NSTextField(labelWithString: "")
    private let readout = NSTextField(labelWithString: "")
    private let slider: NSSlider
    private let title: String, unit: String
    private let onChange: (Double) -> Void

    init(title: String, value: Double, range: ClosedRange<Double>, unit: String, onChange: @escaping (Double) -> Void) {
        self.title = title
        self.unit = unit
        self.onChange = onChange
        slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        super.init(frame: CGRect(x: 0, y: 0, width: 260, height: 44))
        label.stringValue = title
        label.font = .menuFont(ofSize: 0)
        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        readout.textColor = .secondaryLabelColor
        readout.alignment = .right
        slider.target = self
        slider.action = #selector(moved)
        slider.isContinuous = true
        for v in [label, readout, slider] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            readout.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            readout.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
        ])
        show(value)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func show(_ v: Double) { readout.stringValue = "\(Int(v.rounded()))\(unit)" }

    @objc private func moved() {
        let v = slider.doubleValue.rounded()
        show(v)
        onChange(v)
    }
}
