import AppKit

/// Rimlight's Spotify extension (spicetify/rimlight-bridge.js, bundled in the app): with it, Rimlight gets
/// Spotify's beat map, sections and synced lyrics, and plans the show to the song. It runs inside Spotify through
/// Spicetify, an unofficial Spotify mod the user installs themselves; the menu copies the extension in and turns it on.
enum SpotifyExtension {
    static let file = "rimlight-bridge.js"

    /// The spicetify command: the installer's ~/.local/bin, the older ~/.spicetify, or Homebrew.
    static var cli: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/spicetify", "\(home)/.spicetify/spicetify", "/opt/homebrew/bin/spicetify", "/usr/local/bin/spicetify"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    static var bundled: URL? { Bundle.main.url(forResource: "rimlight-bridge", withExtension: "js") }

    enum State { case noSpicetify, notInstalled, outdated, installed }

    /// The last state read, for the menu: reading it runs spicetify, so the menu shows this one and refreshes it
    /// in the background (it's current again the next time the menu opens).
    private(set) static var cached: State?
    static func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let s = state
            DispatchQueue.main.async { cached = s }
        }
    }

    static var state: State {
        guard let cli else { return .noSpicetify }
        guard let dir = userData(cli) else { return .notInstalled }
        let installed = dir.appendingPathComponent("Extensions/\(file)")
        guard let have = try? Data(contentsOf: installed), enabled(cli) else { return .notInstalled }
        if let b = bundled, let want = try? Data(contentsOf: b), want != have { return .outdated }
        return .installed
    }

    /// Ask first (what it is, that it's unofficial), then copy it in, turn it on and patch Spotify without
    /// restarting it: the extension loads the next time Spotify starts.
    static func offerInstall() {
        NSApp.activate()
        guard let cli else {
            let a = NSAlert()
            a.messageText = "Spicetify isn't installed"
            a.informativeText = "Rimlight's Spotify extension runs through Spicetify, an unofficial Spotify mod. Install Spicetify first (one Terminal command, on its site), then come back here."
            a.addButton(withTitle: "Open spicetify.app")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://spicetify.app/docs/getting-started")!) }
            return
        }
        let a = NSAlert()
        a.messageText = "Add Rimlight's extension to Spotify?"
        a.informativeText = "With it, Rimlight gets Spotify's beat map, sections and synced lyrics, and plans the show to the song: builds and drops land on their beats, and a rap song's hook gets the big look. It uses Spicetify, an unofficial Spotify mod, and loads the next time Spotify starts."
        a.addButton(withTitle: "Add to Spotify")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let result = install(cli)
        refresh()
        let done = NSAlert()
        done.messageText = result == nil ? "Added. Quit and reopen Spotify to load it." : "Couldn't add the extension"
        done.informativeText = result ?? "Rimlight's menu shows the song plan once Spotify is back."
        done.runModal()
    }

    /// nil when it worked, else what went wrong.
    private static func install(_ cli: URL) -> String? {
        guard let src = bundled else { return "The extension is missing from Rimlight.app." }
        guard let dir = userData(cli) else { return "spicetify didn't say where its files are." }
        let ext = dir.appendingPathComponent("Extensions", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
            let dst = ext.appendingPathComponent(file)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
        } catch { return "Couldn't copy it into \(ext.path): \(error.localizedDescription)" }
        if !enabled(cli) {
            let (ok, out) = run(cli, ["config", "extensions", file])
            if !ok { return out }
        }
        let (ok, out) = run(cli, ["apply", "-n"])
        return ok ? nil : out + "\n\nIf this is Spicetify's first run, open Terminal and run: spicetify backup apply"
    }

    private static func userData(_ cli: URL) -> URL? {
        let (ok, out) = run(cli, ["path", "userdata"])
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return ok && path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
    }

    private static func enabled(_ cli: URL) -> Bool {
        let (ok, out) = run(cli, ["config", "extensions"])
        return ok && out.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == file }
    }

    private static func run(_ cli: URL, _ args: [String]) -> (Bool, String) {
        let p = Process()
        p.executableURL = cli
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}
