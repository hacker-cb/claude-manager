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
    /// launcher verbatim.
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
    /// Whether `string` is a well-formed URL whose scheme is exactly `claude` (case
    /// insensitive, as URL schemes are). Guards the forwarder against handing anything
    /// other than a real deep link to a launcher.
    public static func isClaudeURL(_ string: String) -> Bool {
        guard let scheme = URLComponents(string: string)?.scheme else { return false }
        return scheme.lowercased() == CoreConstants.claudeURLScheme
    }
}
