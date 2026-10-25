import Foundation

/// Finds a song's hook from its synced lyrics: the hook is the block of lines that comes back, while verses don't.
/// Loudness alone misses it in rap, where the hook is barely louder than the verse (Spotify's analysis of Drake's
/// "Nonstop" gave the plan no loud jump at all, 2026-10-24), but a hook's words repeat two to four times.
public enum HookFinder {
    /// The hook's occurrences as track-time ranges (seconds), earliest first; empty when nothing repeats.
    public static func hooks(_ lines: [LyricLine]) -> [Range<Double>] {
        let sorted = lines.sorted { $0.t < $1.t }
        let words = sorted.map { normalize($0.w) }
        let sung = words.indices.filter { !words[$0].isEmpty }
        guard sung.count >= 4 else { return [] }
        let text = sung.map { words[$0] }
        let n = text.count

        // runs of matching lines: lines i..<i+r come back as j..<j+r
        struct Run { var a: Int, b: Int, length: Int }
        var runs: [Run] = []
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) where same(text[i], text[j]) && (i == 0 || j == 0 || !same(text[i - 1], text[j - 1])) {
                var r = 0
                while i + r < j, j + r < n, same(text[i + r], text[j + r]) { r += 1 }
                runs.append(Run(a: i, b: j, length: r))
            }
        }
        // the hook: the block of 2+ lines that repeats the most (ties: the longer block); a single line counts
        // only if it comes back 3+ times (a chant)
        var best: (start: Int, length: Int, occurrences: [Int])?
        for run in runs where run.length >= 1 {
            let len = run.length
            let block = Array(text[run.a..<(run.a + len)])
            var occ: [Int] = []
            var k = 0
            while k + len <= n {
                // the block again, allowing one line in four to be sung differently (the first line must match)
                let matches = (0..<len).filter { same(text[k + $0], block[$0]) }.count
                if same(text[k], block[0]), matches >= len - len / 4 { occ.append(k); k += len } else { k += 1 }
            }
            guard occ.count >= 2, len >= 2 || occ.count >= 3 else { continue }
            let score = Double(occ.count) * Double(min(len, 8))
            let bestScore = best.map { Double($0.occurrences.count) * Double(min($0.length, 8)) } ?? 0
            let more = occ.count > (best?.occurrences.count ?? 0), longer = len > (best?.length ?? 0)
            if score > bestScore || (score == bestScore && (more || (occ.count == best?.occurrences.count && longer))) {
                best = (occ[0], len, occ)
            }
        }
        guard let hook = best else { return [] }

        // a line lasts until the next line starts (the last one: the typical line length)
        let starts = sung.map { sorted[$0].t / 1000 }
        let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }.sorted()
        let typical = gaps.isEmpty ? 3 : gaps[gaps.count / 2]
        func end(ofLine k: Int) -> Double {
            let idx = sung[k]
            return idx + 1 < sorted.count ? sorted[idx + 1].t / 1000 : starts[k] + typical
        }
        return hook.occurrences.map { o in starts[o]..<end(ofLine: o + hook.length - 1) }
    }

    /// Lowercased words only: no punctuation, no ad-libs in parentheses, no "♪".
    static func normalize(_ s: String) -> String {
        var out = ""
        var depth = 0
        for ch in s.lowercased() {
            if ch == "(" { depth += 1; continue }
            if ch == ")" { depth = max(0, depth - 1); continue }
            guard depth == 0 else { continue }
            if ch.isLetter || ch.isNumber { out.append(ch) } else if ch == " " || ch == "-" { out.append(" ") }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    /// The same line, allowing a word changed here and there (a hook's second time through often is).
    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return !a.isEmpty }
        let x = Set(a.split(separator: " ")), y = Set(b.split(separator: " "))
        guard x.count >= 3, y.count >= 3 else { return false }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.7
    }
}
