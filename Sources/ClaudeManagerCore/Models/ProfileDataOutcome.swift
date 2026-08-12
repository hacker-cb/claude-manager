import Foundation

/// What became of a profile's user-data directory when its launcher was removed.
///
/// Deleting that data is the destructive half of a removal — it holds the profile's Anthropic
/// login and its chat history — and `remove` can decline to do it for reasons the user cannot
/// see from the outside. A `Bool` reported only *whether* it happened, which left the one case
/// worth saying out loud ("you asked to delete this and it is still on disk, here is why")
/// indistinguishable from the two that need no words at all.
public enum ProfileDataOutcome: Sendable, Equatable {
    /// Deleted, as asked — together with its `-3p` managed-config overlay sibling.
    case purged
    /// Deletion was asked for and **declined**: the launchers named here still point at the
    /// same user-data directory, and deleting it would sign them out too. Carries their
    /// display names because the remedy is per-launcher — the user has to remove those before
    /// the data can go.
    case keptSharedWith(launchers: [String])
    /// Deletion was asked for and there was nothing at the path. The overlay sibling is still
    /// swept (it is created independently of the data dir), and the user asked for an absence
    /// they already have.
    case alreadyGone
    /// Deletion was not asked for — "Move Launcher to Trash (keep login)".
    case notRequested

    /// What to tell the user, or `nil` when the removal did exactly what they asked.
    ///
    /// Only `keptSharedWith` speaks. The other three are silent on purpose: two of them were
    /// never asked to delete anything or found nothing to delete, and announcing a purge that
    /// went through would be a notification for "the button did what it says".
    ///
    /// Lives here rather than in the app layer so it is covered by tests — `ClaudeManagerCore`
    /// is the only target the test suite builds against, and a sentence telling someone their
    /// credentials are still on disk is worth a test.
    public func notice(forRemovalOf displayName: String) -> String? {
        guard case let .keptSharedWith(launchers) = self, !launchers.isEmpty else { return nil }
        let single = launchers.count == 1
        return "\(displayName)'s profile data was kept: \(Self.list(launchers)) still "
            + "\(single ? "points" : "point") at the same folder. Remove "
            + "\(single ? "it" : "them") too if you want that data deleted."
    }

    /// Names joined for a sentence — "A", "A and B", "A, B and C". Private because the one
    /// caller is right here; a second one is what would earn it a home of its own.
    private static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
