import Foundation

/// Whether a newer **Claude Manager** exists, as Sparkle last answered.
///
/// Deliberately thinner than ``ClaudeUpdateState``, and for a reason worth stating: this app
/// does not fetch, verify or install its own updates — Sparkle does all of it, including the
/// download, the signature check and the relaunch. What is left for this type to carry is the
/// one fact Sparkle keeps to itself between its own dialogs: that a release is out there.
///
/// So there is no `.downloading`, no `.ready` and no `.failed` here. A failure belongs to
/// Sparkle's own reporting, and a download that is in flight is behind its window.
public enum ManagerUpdateState: Equatable, Sendable {
    /// Nothing found, or nothing asked yet.
    case idle
    /// Sparkle's probe found a release newer than this build.
    case available(version: String)

    /// The release this state is about, when it is about one.
    public var version: String? {
        switch self {
        case .idle: nil
        case let .available(version): version
        }
    }

    /// One line for a tooltip or a heading. Empty for `.idle`, which has nothing to say —
    /// the control it feeds is not shown at all in that state.
    public var statusLine: String {
        switch self {
        case .idle: ""
        case let .available(version): "Claude Manager \(version) is available."
        }
    }
}
