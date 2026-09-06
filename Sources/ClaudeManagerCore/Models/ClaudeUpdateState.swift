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

    /// Whether update work is in flight, so the UI can disable the controls that would
    /// start more of it.
    public var isBusy: Bool {
        switch self {
        case .downloading, .installing: true
        case .idle, .available, .ready, .failed: false
        }
    }

    /// Whether a build is downloaded, verified, and waiting for nothing but a press.
    ///
    /// The one state that moves on nobody's schedule, which is why it is worth naming: a
    /// check running beside it is background noise, and a line that replaced "Claude 1.2.3 is
    /// ready to install" with "Checking…" would take the only sentence that asks for an
    /// action off the screen.
    public var isPreparedForInstall: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Whether this state makes it unsafe to open, close or sweep profiles.
    ///
    /// Narrower than ``isBusy``, and the difference matters: a download touches nothing but
    /// a cache directory and can run for several minutes on a slow line. Gating profile
    /// activity on `isBusy` would make a menu-bar app refuse to open a profile — and stop
    /// refreshing usage — for the whole of a background download that was never in the way.
    /// Only the swap itself is.
    public var blocksProfileActivity: Bool {
        if case .installing = self { return true }
        return false
    }
}

public extension ClaudeUpdateState {
    /// Whether the feed is worth asking again.
    ///
    /// Only work in flight says no, and for a concrete reason each: a download owns the cache
    /// a check would fetch into, and an install owns the staged bundle it is moving into
    /// `/Applications`. A *failed* state, by contrast, must keep retrying — a transient
    /// network error is the common cause, and a state that never asks again turns one bad
    /// moment into a permanent stop.
    ///
    /// **A prepared build used to say no too, and that was the bug.** The reasoning was that a
    /// build already downloaded holds the news, so asking again cannot improve on it. But the
    /// offer waits for a press that may be days away, and Anthropic ships every few days —
    /// so this app went silent exactly where the world kept moving: the toolbar offered a
    /// superseded build indefinitely, `lastClaudeUpdateSuccess` stopped moving (Doctor then
    /// reporting a feed that was answering perfectly well), and the press installed the stale
    /// build — buying a second download and a second round of closing every profile as soon as
    /// the next check finally ran.
    ///
    /// Asking is safe; *acting* on the answer is the narrow part, and belongs to the caller.
    /// A prepared build is replaced only by a release that genuinely supersedes it
    /// (``AvailableUpdate/supersedes(prepared:)``), and never while an install is reading it.
    var allowsCheck: Bool {
        switch self {
        case .downloading, .installing: false
        case .idle, .available, .ready, .failed: true
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

public extension ClaudeUpdateState {
    /// One line saying where update work stands, for the row beside a manual check.
    ///
    /// Reads `lastSuccess` rather than the attempt stamp deliberately: an attempt that never
    /// reached Anthropic says nothing about whether Claude is current, and a check that fails
    /// leaves this state `.idle` — so without this line a feed that has been unreachable all
    /// week is indistinguishable, until Doctor's warning, from a machine that is up to date.
    func statusLine(lastSuccess: Date?, now: Date = Date()) -> String {
        switch self {
        case .idle:
            // "Successful", because that is what the stamp records — and `.idle` is also where a
            // *failed* scheduled check leaves the state, so a machine whose background check has
            // been failing for three days would otherwise read "Last checked 3 d ago" and mean
            // the opposite of what it says.
            lastSuccess.map { "Last successful check \(UsageFormat.age($0, now: now))." }
                ?? "Not checked yet."
        case let .available(update):
            "Claude \(update.version) is available, not downloaded yet."
        case let .downloading(version, _, _):
            "Downloading Claude \(version)…"
        case let .ready(verified):
            "Claude \(verified.version) is ready to install."
        case let .installing(version):
            "Installing Claude \(version)…"
        case let .failed(reason):
            // "Update failed", not "check failed": this state is also where a download, a
            // verification and an install land, and naming the wrong step sends the reader
            // looking for a network problem that isn't there.
            "Update failed: \(reason)"
        }
    }
}
