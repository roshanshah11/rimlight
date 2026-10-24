import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: Engine?
    private var menuBar: MenuBar?

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
            menuBar = MenuBar(engine: e)
        } catch {
            NSLog("Rimlight cannot start: \(error)")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ note: Notification) { engine?.stop() }
}
