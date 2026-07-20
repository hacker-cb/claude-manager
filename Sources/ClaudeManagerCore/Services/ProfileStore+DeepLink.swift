import Foundation

/// Helpers for the `claude://` deep-link scheme. Pure and side-effect free.
public enum DeepLink {
    /// Whether `string` is a well-formed **`claude://`** URL — the hierarchical form with a
    /// non-empty authority (host), not a bare opaque `claude:foo` nor an authority-less
    /// `claude://` / `claude:///path` (which share the scheme but aren't the deep-link shape
    /// the docs, UI, and error messages all refer to). Guards the forwarder against handing
    /// anything other than a real deep link to a launcher.
    public static func isClaudeURL(_ string: String) -> Bool {
        guard string.lowercased().hasPrefix("\(CoreConstants.claudeURLScheme)://"),
              let components = URLComponents(string: string),
              components.scheme?.lowercased() == CoreConstants.claudeURLScheme,
              let host = components.host, !host.isEmpty
        else { return false }
        return true
    }
}
