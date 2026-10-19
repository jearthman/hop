/// Scores window candidates against a typed query.
///
/// Ranking happens in tiers so short queries behave predictably:
///   4. app name starts with the query, or the query is the app name's acronym ("vsc" → Visual Studio Code)
///   3. the title starts with the query, or any word does
///   2. the query is an acronym across app name + title ("sl" → Safari · Login)
///   1. plain fuzzy subsequence match
/// Within a tier, a fuzzy quality score breaks ties; callers break remaining ties by recency.
public enum Matcher {
    private static let tierWeight = 100_000

    public static func score(query: String, appName: String, title: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }

        let combined = title.isEmpty ? appName : appName + " " + title
        let text = Array(combined)
        guard let quality = fuzzyScore(q, text) else { return nil }

        let qs = String(q)
        let appChars = Array(appName)
        let tier: Int
        if appName.lowercased().hasPrefix(qs) || (q.count >= 2 && initials(appChars).hasPrefix(qs)) {
            tier = 4
        } else if title.lowercased().hasPrefix(qs) || anyWordHasPrefix(qs, text) {
            tier = 3
        } else if q.count >= 2 && initials(text).hasPrefix(qs) {
            tier = 2
        } else {
            tier = 1
        }
        return tier * tierWeight + quality
    }

    /// Filters and sorts `items` (assumed to be in recency order) for `query`.
    /// An empty query returns the items unchanged.
    public static func rank<T>(_ items: [T], query: String, fields: (T) -> (appName: String, title: String)) -> [T] {
        if query.allSatisfy(\.isWhitespace) { return items }
        var scored: [(score: Int, index: Int, item: T)] = []
        for (index, item) in items.enumerated() {
            let f = fields(item)
            if let s = score(query: query, appName: f.appName, title: f.title) {
                scored.append((s, index, item))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.map(\.item)
    }

    // MARK: - Internals

    private static func lower(_ c: Character) -> Character {
        c.lowercased().first ?? c
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    /// True where a new word starts: after a separator, at a lower→Upper change, or at a letter↔digit change.
    static func boundaries(_ text: [Character]) -> [Bool] {
        text.indices.map { i in
            let c = text[i]
            guard isWordChar(c) else { return false }
            if i == 0 { return true }
            let p = text[i - 1]
            if !isWordChar(p) { return true }
            if p.isLowercase && c.isUppercase { return true }
            if p.isLetter != c.isLetter { return true }
            return false
        }
    }

    static func initials(_ text: [Character]) -> String {
        let b = boundaries(text)
        return String(text.indices.filter { b[$0] }.map { lower(text[$0]) })
    }

    private static func anyWordHasPrefix(_ prefix: String, _ text: [Character]) -> Bool {
        let b = boundaries(text)
        let lowered = String(text.map(lower))
        let chars = Array(lowered)
        guard chars.count == text.count else { return lowered.contains(prefix) }
        let p = Array(prefix)
        for start in text.indices where b[start] && start + p.count <= chars.count {
            if Array(chars[start..<start + p.count]) == p { return true }
        }
        return false
    }

    /// Best-alignment subsequence score, O(query × text).
    /// Rewards word-boundary hits and consecutive runs; each skipped character costs 1.
    static func fuzzyScore(_ q: [Character], _ text: [Character]) -> Int? {
        let n = text.count, m = q.count
        guard m > 0, m <= n else { return m == 0 ? 0 : nil }
        let lowered = text.map(lower)

        var qi = 0
        for c in lowered where qi < m && c == q[qi] { qi += 1 }
        guard qi == m else { return nil }

        let bound = boundaries(text)
        let neg = Int.min / 4
        let valid = neg / 2
        var prev = [Int](repeating: neg, count: n)
        var cur = prev

        for i in 0..<m {
            // gapBest at j = max over k <= j-2 of prev[k] - (j-1-k)
            var gapBest = neg
            for j in 0..<n {
                if i > 0 && j >= 2 { gapBest = max(gapBest - 1, prev[j - 2] - 1) }
                cur[j] = neg
                guard lowered[j] == q[i] else { continue }
                let bonus = 10 + (bound[j] ? 30 : 0)
                if i == 0 {
                    cur[j] = bonus - min(j, 15)
                } else {
                    var best = neg
                    if j >= 1 && prev[j - 1] > valid { best = prev[j - 1] + 20 }
                    if gapBest > valid { best = max(best, gapBest) }
                    if best > valid { cur[j] = best + bonus }
                }
            }
            swap(&prev, &cur)
        }
        let result = prev.max() ?? neg
        return result > valid ? result : nil
    }
}
