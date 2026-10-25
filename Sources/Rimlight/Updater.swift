import AppKit
import RimlightCore

/// Looks for a newer release on GitHub (the repo in Info.plist's RimlightUpdateRepo) a minute after launch and then
/// once a day. A newer one shows in the menu as "Update to Rimlight X…", which downloads its DMG in the browser.
/// It only reads the public releases list: nothing about this Mac is sent, and nothing installs by itself.
final class Updater {
    private(set) var available: GitHubRelease?
    var onChange: (() -> Void)?
    private var timer: Timer?
    private let repo = Bundle.main.object(forInfoDictionaryKey: "RimlightUpdateRepo") as? String
    private let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    func start(enabled: @escaping () -> Bool) {
        let check = { [weak self] in if enabled() { self?.check() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: check)
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in check() }
    }

    func check() {
        guard let repo, let current, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let r = GitHubRelease.parse(data), Version.isNewer(r.version, than: current) else { return }
            DispatchQueue.main.async {
                guard let self, self.available != r else { return }
                self.available = r
                self.onChange?()
            }
        }.resume()
    }

    func openDownload() {
        guard let r = available else { return }
        NSWorkspace.shared.open(r.download ?? r.page)
    }
}
