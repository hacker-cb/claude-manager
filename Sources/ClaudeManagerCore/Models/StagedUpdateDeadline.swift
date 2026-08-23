import Foundation

/// How long a staged Claude update has been waiting, and roughly when Claude will stop
/// waiting and restart the default profile by itself.
///
/// Claude's updater force-restarts once an update has been pending for
/// `autoUpdaterEnforcementHours` — 72 h by default, and the policy validates as
/// `int().gt(0).lte(72)`, so a deployment can only *shorten* that window, never disable it.
/// Only `disableAutoUpdates` prevents the timer arming at all, and the default profile is
/// deliberately the one profile that keeps its updater (clones would each download the same
/// build into one shared cache).
///
/// The restart is designed to go unnoticed: it defers while the system has been used in the
/// last 10 minutes and while any session is running, so it lands when nobody is watching —
/// which is exactly why it reads as the app acting on its own.
///
/// **Every number here is an estimate, and the type says so.** Claude's counter lives in its
/// updater's memory, not on disk, so the only clock we have is when *we* first saw the
/// staged version. Two ways that is wrong: the wait may have started before Claude Manager
/// was looking, and the restart defers indefinitely while the machine is in use. So this
/// predicts *no earlier than*, and callers word it with "about".
public struct StagedUpdateDeadline: Equatable, Sendable {
    /// When this staged version was first observed by Claude Manager.
    public let firstSeen: Date
    /// The enforcement window in force, in hours.
    public let enforcementHours: Double

    /// Claude's documented default. Kept here rather than at the call site so the one place
    /// that knows the policy is the one place that models it.
    public static let defaultEnforcementHours: Double = 72

    public init(firstSeen: Date, enforcementHours: Double = StagedUpdateDeadline.defaultEnforcementHours) {
        self.firstSeen = firstSeen
        // A non-positive window would put the estimate in the past forever; the policy
        // itself refuses one, so clamp rather than model an impossible deployment.
        self.enforcementHours = max(1, enforcementHours)
    }

    /// How long the update has been waiting, never negative — a clock that moved backwards
    /// (or a record written by a future build) must not read as a negative wait.
    public func waited(asOf now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(firstSeen))
    }

    /// The earliest moment Claude might restart the default profile on its own.
    public var earliestForcedRestart: Date {
        firstSeen.addingTimeInterval(enforcementHours * 3600)
    }

    /// Time left before that moment, or zero once it has passed.
    public func remaining(asOf now: Date) -> TimeInterval {
        max(0, earliestForcedRestart.timeIntervalSince(now))
    }

    /// Whether the forced restart is close enough to be worth warning about — including
    /// after the window has elapsed, since a deferred restart still hasn't happened and the
    /// warning stays true until the update is applied.
    public func isApproaching(asOf now: Date, lead: TimeInterval) -> Bool {
        remaining(asOf: now) <= max(0, lead)
    }

    /// How far ahead of the estimate to warn. Four hours is long enough to act on at the end
    /// of a working day and short enough that the estimate hasn't drifted into fiction.
    public static let warningLead: TimeInterval = 4 * 3600

    /// Fold the currently-staged version into the recorded first sightings.
    ///
    /// The rules are small but each one is a bug if inverted, so they live here — in Core,
    /// under test — rather than inline in the app layer:
    ///
    /// - **A known version keeps its original date.** Re-stamping it on every refresh would
    ///   hold the wait at zero and the warning would never fire.
    /// - **Only the current version is kept.** Otherwise the record grows a row per Claude
    ///   release for the life of the install, and the file is meant to be a fact, not a log.
    /// - **No staged update clears everything**, so a version staged again later — after a
    ///   rollback, or a re-download — is a genuinely fresh wait.
    ///
    /// Callers prune their notification ledgers to the returned keys, which is what makes a
    /// fresh wait able to notify again.
    public static func recordSighting(
        of version: String?,
        into existing: [String: Date],
        now: Date
    ) -> [String: Date] {
        // **Nothing staged does not clear the record.** `StagedUpdateProbe.probe()` returns
        // nil for a genuinely-cleared job *and* for a transient read — the state file is
        // rewritten on every re-arm, and mid-rewrite it parses as nothing. Clearing on that
        // would restart the wait each time the same update retried, so the estimate would
        // never mature and the warning would never fire; it would also re-arm the
        // "downloaded" notification for a version already announced. The record is one row,
        // so keeping a stale one costs nothing, and the next *different* version replaces it.
        guard let version else { return existing }
        guard let seen = existing[version] else { return [version: now] }
        return [version: seen]
    }
}
