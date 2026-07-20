import Foundation

/// The Claude-Manager-owned managed-config overlay for a single Claude account (a
/// cloned profile or the default account).
///
/// Claude Desktop resolves a *tiered* "managed config"; its per-userData **local
/// tier** lives at `<userData>-3p/configLibrary` and is honored when no MDM
/// managed-preferences plist is present. We pre-seed that tier so a clone starts with
/// its Squirrel auto-updater disabled (clones share the one on-disk
/// `/Applications/Claude.app`, so only the default account needs to update).
///
/// The `claude://` handler is **not** managed here. Claude Manager owns the scheme via
/// the event-driven ``LaunchServicesHandlerGuard``, never by writing
/// `disableDeepLinkRegistration`: that key makes Claude *drop* every forwarded non-auth
/// deep link (`dropping deep link (disableDeepLinkRegistration)`) — the very hand-off the
/// broker performs to route a link to a chosen account. It survives only in ``managedKeys``
/// so a reconcile removes one an earlier build wrote into a clone.
///
/// The on-disk form is a **flat** JSON object of enterprise-policy keys (verified
/// against Claude `CoreConstants.claudeManagedConfigValidatedVersion`): the nested
/// `autoUpdate.disabled` shape is *not* what the resolver reads. This value type is
/// the typed desired-state; ``flatEntries`` maps it to those flat keys and
/// ``managedKeys`` is the full set of keys we own — so a reconcile can drop a key we
/// no longer set while preserving keys we never touch.
public struct ProfileManagedConfig: Equatable, Sendable {
    /// Disable Claude's Squirrel auto-updater (flat key `disableAutoUpdates`).
    /// Verified: the instance logs `[updater] Auto-updates disabled by enterprise
    /// policy` and performs no check / download.
    public var disableAutoUpdates: Bool

    public init(disableAutoUpdates: Bool = false) {
        self.disableAutoUpdates = disableAutoUpdates
    }

    /// The overlay a cloned profile gets: the updater is the default account's job, so a
    /// clone always disables its own. The `claude://` handler is held by the guard, not
    /// written here — a forwarded deep link must reach the clone, and
    /// `disableDeepLinkRegistration` would make Claude drop it.
    public static func clone() -> ProfileManagedConfig {
        ProfileManagedConfig(disableAutoUpdates: true)
    }

    /// The overlay the **default account** gets: **always empty**. The default is the
    /// update leader (auto-update stays on), and Claude Manager holds `claude://` for it
    /// via the event-driven handler guard — never by writing `disableDeepLinkRegistration`
    /// into the default account. This empty overlay still drives a reconcile that
    /// *removes* any such key left by an earlier build.
    public static let defaultAccount = ProfileManagedConfig()

    /// Flat enterprise-policy keys this overlay currently wants *present* → their
    /// JSON values. A disabled/`false` flag is omitted, so the reconcile deletes a
    /// previously-set key rather than writing `false` (both mean "not enforced", and
    /// omission keeps the file minimal).
    public var flatEntries: [String: Bool] {
        var entries: [String: Bool] = [:]
        if disableAutoUpdates { entries[Key.disableAutoUpdates] = true }
        return entries
    }

    /// Every flat key this type may write *or clean up*. A reconcile removes any of these
    /// *not* in ``flatEntries`` (so toggling a setting off cleans up), while keys outside
    /// this set — another tool's, or Claude's own — are always preserved.
    /// `disableDeepLinkRegistration` stays here though we no longer write it, so the
    /// reconcile strips it from a clone an earlier build enabled it on.
    public static let managedKeys: Set<String> = [Key.disableAutoUpdates, Key.disableDeepLinkRegistration]

    /// The flat key for Claude's "disable `claude://` handling" policy. We never *write* it
    /// — the guard owns the handler — but expose the name so a reconcile/Doctor can detect
    /// and strip one an earlier build left behind (it makes Claude drop forwarded links).
    public static let disableDeepLinkRegistrationKey = Key.disableDeepLinkRegistration

    /// Flat key names, pinned to the validated Claude schema. Kept private so the
    /// literal strings have a single definition shared by ``flatEntries`` and
    /// ``managedKeys``.
    private enum Key {
        static let disableAutoUpdates = "disableAutoUpdates"
        static let disableDeepLinkRegistration = "disableDeepLinkRegistration"
    }
}
