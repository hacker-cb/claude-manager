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
/// log stream --predicate 'subsystem == "io.github.hacker-cb.claude-manager"'
/// ```
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
