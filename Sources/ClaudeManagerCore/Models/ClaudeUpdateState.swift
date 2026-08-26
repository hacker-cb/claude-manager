import Foundation

/// Where the app is in the business of updating Claude itself.
///
/// One value rather than a handful of booleans, because the states are genuinely exclusive
/// and the interesting bugs in an updater are the combinations that should not exist —
/// "downloading" and "ready" at once, or a version offered while another installs.
public enum ClaudeUpdateState: Equatable, Sendable {
    /// Nothing to do: either the installed build is current, or nothing has been checked yet.
    case idle
    /// A newer release exists and has not been fetched yet.
    case available(AvailableUpdate)
    /// Fetching. `total` is nil until the server says how big it is.
    case downloading(version: String, received: Int64, total: Int64?)
    /// Downloaded, unpacked, and proved to be Anthropic's. Waiting for a deliberate press.
    case ready(VerifiedUpdate)
    /// The swap is in flight: every profile is closing, or the bundle is being replaced.
    case installing(version: String)
    /// The last attempt failed, with something worth showing the user.
    case failed(reason: String)

    /// The release this state is about, when it is about one.
    public var version: String? {
        switch self {
        case .idle, .failed: nil
        case let .available(update): update.version
        case let .downloading(version, _, _): version
        case let .ready(verified): verified.version
        case let .installing(version): version
        }
    }

    /// Whether work is in flight, so the UI can disable the controls that would start more.
    public var isBusy: Bool {
        switch self {
        case .downloading, .installing: true
        case .idle, .available, .ready, .failed: false
        }
    }
}

public extension ClaudeUpdateState {
    /// Whether the feed is worth asking again.
    ///
    /// Two rules, and the second is the one that is easy to get wrong. A prepared build is
    /// the state that already has news in it — re-checking cannot improve on it, and a check
    /// that discarded it would throw away a finished download. A *failed* one, by contrast,
    /// must keep retrying: a transient network error is the common cause, and a state that
    /// never asks again turns one bad moment into a permanent stop.
    var allowsCheck: Bool {
        switch self {
        case .ready, .downloading, .installing: false
        case .idle, .available, .failed: true
        }
    }

    /// Whether enough time has passed to ask again.
    ///
    /// `lastCheck` is nil the first time, which is always due. Kept as a free function of its
    /// inputs so the schedule is testable without a clock, an app, or a network.
    static func isCheckDue(lastCheck: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastCheck else { return true }
        // A `lastCheck` in the future means the clock moved backwards — a timezone change, or
        // a machine that woke with a bad time. Treated as due: waiting out an interval
        // measured from a future that never happened could mean waiting indefinitely.
        guard now >= lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}
