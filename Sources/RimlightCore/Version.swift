import Foundation

/// Release versions as GitHub tags and CFBundleShortVersionString write them: "1.2.0", "v1.2", "1.10.3".
public enum Version {
    /// The numeric parts, or nil if it isn't a plain release version (a "1.2.0-beta" tag isn't offered as an update).
    public static func parts(_ s: String) -> [Int]? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let p = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !p.isEmpty, p.count <= 4, p.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return p.map { $0! }
    }

    /// `a` is a later release than `b` (missing parts count as 0: 1.2 == 1.2.0).
    public static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parts(a), let y = parts(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// The latest release as GitHub's API describes it (GET /repos/{owner}/{repo}/releases/latest): its version, its
/// page and its DMG. Drafts, prereleases and tags that aren't plain versions don't count.
public struct GitHubRelease: Equatable, Sendable {
    public let version: String
    public let page: URL
    public let download: URL?

    public static func parse(_ data: Data) -> GitHubRelease? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String, Version.parts(tag) != nil,
              (j["draft"] as? Bool) != true, (j["prerelease"] as? Bool) != true,
              let page = (j["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let dmg = (j["assets"] as? [[String: Any]])?.lazy.compactMap { $0["browser_download_url"] as? String }
            .first { $0.lowercased().hasSuffix(".dmg") }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return GitHubRelease(version: version, page: page, download: dmg.flatMap(URL.init(string:)))
    }
}
