import Foundation

/// The Claude-Manager-owned managed-config overlay for a single cloned profile.
///
/// Claude Desktop resolves a *tiered* "managed config"; its per-userData **local
/// tier** lives at `<userData>-3p/configLibrary` and is honored when no MDM
/// managed-preferences plist is present. We pre-seed that tier so a clone starts
/// with, for example, its Squirrel auto-updater disabled — clones all share the one
/// on-disk `/Applications/Claude.app`, so only the default account needs to
/// check / download / stage updates.
///
/// The on-disk form is a **flat** JSON object of enterprise-policy keys (verified
/// against Claude `CoreConstants.claudeManagedConfigValidatedVersion`): the nested
/// `autoUpdate.disabled` shape is *not* what the resolver reads. This value type is
/// the typed desired-state; ``flatEntries`` maps it to those flat keys and
/// ``managedKeys`` is the full set of keys we own — so a reconcile can drop a key we
/// no longer set while preserving keys we never touch.
public struct ProfileManagedConfig: Equatable, Sendable {
    /// Disable Claude's Squirrel auto-updater in this clone (flat key
    /// `disableAutoUpdates`). Verified: the instance logs `[updater] Auto-updates
    /// disabled by enterprise policy` and performs no check / download.
    public var disableAutoUpdates: Bool

    public init(disableAutoUpdates: Bool = false) {
        self.disableAutoUpdates = disableAutoUpdates
    }

    /// The overlay every cloned profile gets: the updater is the default account's
    /// job, so a clone disables its own.
    public static let clone = ProfileManagedConfig(disableAutoUpdates: true)

    /// Flat enterprise-policy keys this overlay currently wants *present* → their
    /// JSON values. A disabled/`false` flag is omitted, so the reconcile deletes a
    /// previously-set key rather than writing `false` (both mean "not enforced", and
    /// omission keeps the file minimal).
    public var flatEntries: [String: Bool] {
        var entries: [String: Bool] = [:]
        if disableAutoUpdates { entries[Key.disableAutoUpdates] = true }
        return entries
    }

    /// Every flat key this type may write. A reconcile removes any of these *not* in
    /// ``flatEntries`` (so toggling a setting off cleans up), while keys outside this
    /// set — another tool's, or Claude's own — are always preserved.
    public static let managedKeys: Set<String> = [Key.disableAutoUpdates]

    /// Flat key names, pinned to the validated Claude schema. Kept private so the
    /// literal strings have a single definition shared by ``flatEntries`` and
    /// ``managedKeys``.
    private enum Key {
        static let disableAutoUpdates = "disableAutoUpdates"
    }
}
