import Foundation
import OSLog

/// Structured logging for the core.
///
/// The app layer has had its own `Log` for a while; the core had none, and the night the
/// Claude updater misbehaved that turned out to matter: the interactive apply path left no
/// trace at all, so reconstructing what this app did meant reading *Squirrel's* log and
/// guessing at ours. Anything that touches `/Applications/Claude.app`, the network, or the
/// user's profiles now says so out loud.
///
/// Stream it with:
///
/// ```
/// log stream --predicate 'subsystem BEGINSWITH "io.github.hacker-cb.claude-manager"'
/// ```
///
/// A prefix match rather than equality on purpose: the subsystem is the running bundle's
/// id, and a Debug build deliberately carries its own
/// (`io.github.hacker-cb.claude-manager.dev`, see DEVELOPMENT.md). An `==` predicate is
/// exactly the one that shows nothing while you are debugging.
///
/// **On `privacy:`** — `os_log` redacts interpolated values by default, which is why the
/// old logs were half-unreadable. Release versions, feed URLs, HTTP statuses and byte
/// counts are public facts and are marked `.public` so a log is worth reading; anything
/// derived from the user's filesystem stays default-private or goes through
/// `PathUtils.abbreviatingHome`.
enum CoreLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.hacker-cb.claude-manager"

    /// Checking for, downloading, verifying and installing a Claude Desktop update.
    static let update = Logger(subsystem: subsystem, category: "update")
}

public extension URL {
    /// A privacy-safe rendering for logs: `scheme://host/path`, with any query replaced by
    /// `?…`.
    ///
    /// Two unrelated reasons to never log the query, which is why this lives beside the
    /// logger rather than at either call site. A `claude://` deep link can carry an OAuth
    /// `code` on an `mcp-auth-callback`; and a release download is a plain path today, but
    /// the endpoint serving it is undocumented — the day it starts handing out presigned
    /// URLs, `?Signature=…&Key-Pair-Id=…` is a credential, and a log line written months
    /// earlier would be the thing leaking it.
    var logDescription: String {
        let components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        let scheme = components?.scheme ?? "?"
        let host = components?.host ?? ""
        let path = components?.path ?? ""
        let querySuffix = (components?.query?.isEmpty == false) ? "?…" : ""
        return "\(scheme)://\(host)\(path)\(querySuffix)"
    }
}
