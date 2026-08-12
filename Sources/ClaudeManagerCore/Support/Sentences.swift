import Foundation

/// Small helpers for building sentences the user reads. Shared because the alternative is
/// each call site rolling its own — and the two that exist already disagreed about how to
/// join a list before this was pulled out.
enum Sentences {
    /// Names joined for a sentence — "A", "A and B", "A, B and C".
    ///
    /// Never used as a possessive: "A and B's" reads as belonging to B alone. Callers phrase
    /// around it ("the data for A and B") instead.
    static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// `text` with terminal punctuation, so it can be followed by another sentence.
    ///
    /// The reason inside a failure message comes from Foundation or from an interpolated
    /// error, and whether it ends in a full stop is not ours to know — without this, a reason
    /// that does not runs straight into the sentence after it.
    static func terminated(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}
