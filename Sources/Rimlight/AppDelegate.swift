import AppKit
import RimlightCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: Engine?
    private var menuBar: MenuBar?
    private var welcome: Welcome?
    private let updater = Updater()

    func applicationDidFinishLaunching(_ note: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            NSApp.terminate(nil)   // already running
            return
        }
        do {
            let e = try Engine()
            e.start()
            engine = e
            menuBar = MenuBar(engine: e, updater: updater)
            updater.start { [weak e] in e?.settings.checkForUpdates ?? false }
            if !e.settings.welcomed { showWelcome(e) }
        } catch {
            NSLog("Rimlight cannot start: \(error)")
            let a = NSAlert()
            a.messageText = "Rimlight can't start"
            a.informativeText = "It couldn't set up drawing on this Mac's graphics (Metal): \(error). Rimlight needs macOS 15 or later on a Mac that supports Metal."
            NSApp.activate()
            a.runModal()
            NSApp.terminate(nil)
        }
    }

    private func showWelcome(_ e: Engine) {
        let w = Welcome()
        w.onDone = { [weak self] in
            e.change { $0.welcomed = true }
            self?.welcome = nil
        }
        welcome = w
        w.show()
    }

    func applicationWillTerminate(_ note: Notification) { engine?.stop() }
}
