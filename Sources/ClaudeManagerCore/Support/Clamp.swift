import Foundation

extension Comparable {
    /// Constrain a value to a closed range: below the lower bound → lower bound, above the
    /// upper → upper. The single shared clamp used across the core (badge geometry, usage
    /// fractions), so the operation lives in one place.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
