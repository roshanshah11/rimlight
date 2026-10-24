import AppKit
import RimlightCore

/// The menu bar light: what's playing, the beat source, and every setting the CLI can change.
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

        menu.addItem(info(engine.songLine ?? "Nothing playing in Spotify"))
        let beats = engine.beatSource + (engine.tempo.map { String(format: ", %.0f BPM", $0) } ?? "")
        menu.addItem(info("Beats: \(beats)"))
        menu.addItem(.separator())

        menu.addItem(toggle("Glow on", s.enabled) { $0.enabled.toggle() })
        let motion = NSMenuItem(title: "Motion", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (m, label) in [(Motion.beat, "Beat: pulse on every kick"), (.flow, "Flow: breathe with the music"),
                           (.steady, "Steady: no movement")] {
            sub.addItem(toggle(label, s.motion == m) { $0.motion = m })
        }
        motion.submenu = sub
        menu.addItem(motion)
        menu.addItem(.separator())

        menu.addItem(slider("Brightness", s.brightness * 100, 0...100, unit: "%") { s, v in s.brightness = v / 100 })
        menu.addItem(slider("Beat strength", s.reactivity * 100, 0...100, unit: "%") { s, v in s.reactivity = v / 100 })
        menu.addItem(slider("Glow reach", s.glow, 0...120, unit: " pt") { s, v in s.glow = v })
        menu.addItem(slider("Line", s.thickness, 1...12, unit: " pt") { s, v in s.thickness = v })
        menu.addItem(slider("Sync", s.syncOffsetMs, -300...300, unit: " ms") { s, v in s.syncOffsetMs = v })
        menu.addItem(.separator())

        menu.addItem(toggle("Colors from album art", s.colorSource == .album) {
            $0.colorSource = $0.colorSource == .album ? .custom : .album
        })
        menu.addItem(toggle("Lyrics", s.lyrics) { $0.lyrics.toggle() })
        menu.addItem(toggle("HDR flashes on the XDR screen", s.hdr) { $0.hdr.toggle() })
        menu.addItem(toggle("Wrap the notch", s.wrapNotch) { $0.wrapNotch.toggle() })
        menu.addItem(toggle("Fade out when music stops", s.idleWhenPaused) { $0.idleWhenPaused.toggle() })
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Rimlight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
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
