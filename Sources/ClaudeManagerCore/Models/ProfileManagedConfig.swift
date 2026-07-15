import Foundation

/// The Claude-Manager-owned managed-config overlay for a single Claude account (a
/// cloned profile or the default account).
///
/// Claude Desktop resolves a *tiered* "managed config"; its per-userData **local
/// tier** lives at `<userData>-3p/configLibrary` and is honored when no MDM
/// managed-preferences plist is present. We pre-seed that tier so an account starts
/// with, for example, its Squirrel auto-updater disabled (clones share the one on-disk
/// `/Applications/Claude.app`, so only the default account needs to update) or its
/// deep-link handler registration suppressed (so Claude Manager can own `claude://`).
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

    /// Stop Claude re-registering itself as the `claude://` default handler on launch
    /// (flat key `disableDeepLinkRegistration`), so Claude Manager's broker can hold
    /// the scheme. Verified: non-auth links are dropped (`dropping deep link
    /// (disableDeepLinkRegistration)`) while login / magic-link / SSO links are still
    /// handled — so a forwarded auth callback works.
    public var disableDeepLinkRegistration: Bool

    public init(disableAutoUpdates: Bool = false, disableDeepLinkRegistration: Bool = false) {
        self.disableAutoUpdates = disableAutoUpdates
        self.disableDeepLinkRegistration = disableDeepLinkRegistration
    }

    /// The overlay a cloned profile gets: the updater is the default account's job, so
    /// a clone always disables its own; deep-link registration is suppressed only when
    /// the broker owns the handler.
    public static func clone(deepLinkBrokerEnabled: Bool = false) -> ProfileManagedConfig {
        ProfileManagedConfig(disableAutoUpdates: true, disableDeepLinkRegistration: deepLinkBrokerEnabled)
    }

    /// The overlay the **default account** gets: **always empty**. The default is the
    /// update leader (auto-update stays on), and Claude Manager holds `claude://` for it
    /// via the event-driven handler guard — never by writing `disableDeepLinkRegistration`
    /// into the default account. Writing that key would silently break the default's deep
    /// links if Claude Manager were removed without disabling the broker first; the guard
    /// instead simply stops holding the handler when CM isn't running. This empty overlay
    /// still drives a reconcile that *removes* any such key left by an earlier build.
    public static let defaultAccount = ProfileManagedConfig()

    /// Flat enterprise-policy keys this overlay currently wants *present* → their
    /// JSON values. A disabled/`false` flag is omitted, so the reconcile deletes a
    /// previously-set key rather than writing `false` (both mean "not enforced", and
    /// omission keeps the file minimal).
    public var flatEntries: [String: Bool] {
        var entries: [String: Bool] = [:]
        if disableAutoUpdates { entries[Key.disableAutoUpdates] = true }
        if disableDeepLinkRegistration { entries[Key.disableDeepLinkRegistration] = true }
        return entries
    }

    /// Every flat key this type may write. A reconcile removes any of these *not* in
    /// ``flatEntries`` (so toggling a setting off cleans up), while keys outside this
    /// set — another tool's, or Claude's own — are always preserved.
    public static let managedKeys: Set<String> = [Key.disableAutoUpdates, Key.disableDeepLinkRegistration]

    /// Flat key names, pinned to the validated Claude schema. Kept private so the
    /// literal strings have a single definition shared by ``flatEntries`` and
    /// ``managedKeys``.
    private enum Key {
        static let disableAutoUpdates = "disableAutoUpdates"
        static let disableDeepLinkRegistration = "disableDeepLinkRegistration"
    }
}
