import Foundation

public extension ProfileStore {
    /// Forward a `claude://` deep link to a specific managed profile by launching its
    /// launcher with the URL as an argument: `open -n <launcher>.app --args <url>`.
    /// The launcher's `exec "$REAL" --user-data-dir=P "$@"` passes it through, and
    /// Claude scans `argv` at startup for `claude://` URLs — so a **not-running** target
    /// receives the link (e.g. a login/SSO callback lands on the chosen account).
    ///
    /// Delivery only works when the target is **not already running**: the launcher's
    /// duplicate-instance guard exits without forwarding if an instance already holds the
    /// profile's lock. Callers should surface that case rather than assume delivery.
    ///
    /// Only a genuine `claude://` URL is forwarded — never an arbitrary argument — so a
    /// malformed or foreign-scheme string is rejected instead of being handed to the
    /// launcher verbatim. The run is a direct `execve` (no shell), and the URL is a single
    /// argv element after `--args`, so it can't be re-split or reinterpreted as a flag.
    ///
    /// Residual exposure (accepted): a cold-start deep link reaches Claude via `argv`, so a
    /// login callback's OAuth `code` is briefly on the command line of `open`, the launcher,
    /// and Claude — readable by another *same-user* process. That is inherent to delivering
    /// a URL to an argv-scanning Electron app at launch (the native Apple-event path can't
    /// address a specific not-running launcher instance); it needs a pre-existing same-user
    /// foothold to exploit.
    func openForwarding(_ profile: Profile, url: String) throws {
        guard DeepLink.isClaudeURL(url) else {
            throw ClaudeManagerError.invalidDeepLink(url)
        }
        try runner.runChecked(CoreConstants.openPath, ["-n", profile.appPath, "--args", url])
    }

    /// Forward a `claude://` deep link to the **default account** (the untouched real
    /// app), by launching a fresh instance of it with the URL as an argument. Callers
    /// MUST first check `runningDefaultPID` and only use this when the default is *not*
    /// running — a second `open -n` on a live default runs two instances on one
    /// user-data-dir and corrupts its LevelDB (same rule as `openReal`).
    func openRealForwarding(url: String) throws {
        guard DeepLink.isClaudeURL(url) else {
            throw ClaudeManagerError.invalidDeepLink(url)
        }
        try runner.runChecked(CoreConstants.openPath, ["-n", realClaude.appURL.path, "--args", url])
    }
}

/// Helpers for the `claude://` deep-link scheme. Pure and side-effect free.
public enum DeepLink {
    /// Whether `string` is a well-formed **`claude://`** URL — the hierarchical form with
    /// an authority, not a bare opaque `claude:foo` (which shares the scheme but isn't the
    /// deep-link shape the docs, UI, and error messages all refer to). Guards the forwarder
    /// against handing anything other than a real deep link to a launcher.
    public static func isClaudeURL(_ string: String) -> Bool {
        guard string.lowercased().hasPrefix("\(CoreConstants.claudeURLScheme)://") else { return false }
        return URLComponents(string: string)?.scheme?.lowercased() == CoreConstants.claudeURLScheme
    }
}
