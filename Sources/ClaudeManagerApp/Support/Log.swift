import Foundation
import OSLog

/// Structured logging for the app layer. One `Logger` per concern, all under the app's
/// bundle-id subsystem so they can be streamed/filtered together:
///
/// ```
/// log stream --predicate 'subsystem == "io.github.hacker-cb.claude-manager"'
/// ```
///
/// The deep-link path used to be silent, which made a "nothing happened" report
/// impossible to diagnose (LaunchServices redacts the URL in its own logs). These
/// loggers restore a paper trail for the broker: intake, filtering, the handler guard,
/// the picker, and forwarding.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.hacker-cb.claude-manager"

    /// Deep-link intake, routing, picker, and forwarding.
    static let deepLink = Logger(subsystem: subsystem, category: "deeplink")
    /// The `claude://` handler broker (registration, hold/re-assert, restore).
    static let broker = Logger(subsystem: subsystem, category: "broker")
}

extension URL {
    /// A privacy-safe rendering for logs: `scheme://host/path` with the query dropped.
    /// A `claude://` deep link's query can carry secrets (e.g. an OAuth `code` on an
    /// `mcp-auth-callback`), so the value is never logged — only whether one was present,
    /// which is enough to diagnose routing without leaking the token.
    var logDescription: String {
        let components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        let scheme = components?.scheme ?? "?"
        let host = components?.host ?? ""
        let path = components?.path ?? ""
        let querySuffix = (components?.query?.isEmpty == false) ? "?…" : ""
        return "\(scheme)://\(host)\(path)\(querySuffix)"
    }
}
