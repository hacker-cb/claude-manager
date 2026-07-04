import Foundation

/// Ordering for Claude's dotted-numeric marketing versions (e.g. `1.18286.0`).
///
/// Compares component-by-component as integers so `1.18286.0` sorts above
/// `1.17377.2` (a lexicographic string compare would get `9` vs `17` wrong).
/// Missing trailing components read as `0`, so `1.18` equals `1.18.0`. A
/// non-numeric component is treated as `0` rather than throwing — a malformed
/// version simply never reads as "newer", which keeps the update prompt from
/// firing on garbage.
enum VersionOrder {
    /// True when `candidate` is a strictly newer version than `baseline`.
    static func isNewer(_ candidate: String, than baseline: String) -> Bool {
        compare(candidate, baseline) == .orderedDescending
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = components(lhs)
        let b = components(rhs)
        for index in 0 ..< max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
