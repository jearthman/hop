import Foundation

/// A dotted numeric version like "1.2.3", parsed leniently from tags such as "v1.2" or "1.2.3-beta".
/// Missing components count as zero, so "1.2" == "1.2.0".
public struct AppVersion: Comparable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        // Ignore pre-release / build suffixes.
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = s[..<cut] }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        components = numbers
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
