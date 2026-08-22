import Foundation

/// ShipIt (Squirrel.Mac) as a **live installer process**, and how its last attempt ended.
///
/// `StagedUpdateProbe` answers "is an update armed?"; this answers "is the swap happening
/// right now, and if it stopped, why?". The distinction is load-bearing, because the swap
/// has **no upper bound we can know in advance**: measured across a month of real installs
/// it takes 3–5 s from `Beginning installation` to `Moving bundle`, but under disk
/// contention the same 800 MB bundle has taken 28 s and 57 s. A fixed timer therefore
/// cannot separate "still copying" from "gave up" — and guessing wrong is not passive: the
/// caller relaunches profiles, ShipIt re-checks its instance count mid-install and aborts
/// with `App Still Running Error`, so an install that was going through is destroyed by the
/// very wait that was supposed to protect it. Ask the process instead of the clock.
///
/// The failure reason is read from ShipIt's own `stderr` log, and only from the bytes
/// written **after** a recorded offset — so a stale error from a previous attempt can never
/// be reported as this attempt's outcome. Every read is defensive: an unreadable or absent
/// log yields `nil`, never a throw.
public struct ShipItProbe {
    /// Bundle id of the app being updated (`com.anthropic.claudefordesktop`), which is also
    /// how ShipIt's own job is named on its argv.
    let bundleID: String
    /// ShipIt's `stderr` log — the sibling of `ShipItState.plist` in its per-bundle cache.
    let stderrPath: String
    let runner: CommandRunner
    let fileManager: FileManager

    public init(
        bundleID: String,
        stderrPath: String,
        runner: CommandRunner,
        fileManager: FileManager = .default
    ) {
        self.bundleID = bundleID
        self.stderrPath = stderrPath
        self.runner = runner
        self.fileManager = fileManager
    }

    /// Whether a ShipIt process for this bundle is alive — with **"can't tell" kept apart
    /// from "no"**, because the two callers need opposite answers to it.
    ///
    /// Matched on the executable name plus the job label ShipIt carries as its first
    /// argument (`…/Resources/ShipIt com.anthropic.claudefordesktop.ShipIt …`), so another
    /// app's updater — VS Code and GitKraken ship the same Squirrel binary — never counts
    /// as ours.
    ///
    /// Only `pgrep`'s exit **1** means "nothing matched"; 2 is a usage error, 3 a fatal one,
    /// and a failure to spawn it has no exit code at all. Exit 0 means something *did*
    /// match, so it counts as running even when the captured output is unreadable — the
    /// exit status is the answer, the pid is only a bonus.
    public enum Liveness: Equatable, Sendable {
        /// Matched, and this is the process.
        case running(pid: Int32)
        /// Matched, but the pid could not be read back.
        case runningPIDUnknown
        /// `pgrep` said nothing matched.
        case gone
        /// The probe itself failed — this says nothing about the installer.
        case unknown
    }

    public func liveness() -> Liveness {
        let pattern = "/ShipIt " + PathUtils.regexEscaped(bundleID) + "\\.ShipIt"
        guard let output = try? runner.run(CoreConstants.pgrepPath, ["-f", pattern]) else {
            return .unknown // couldn't even run the probe
        }
        switch output.exitCode {
        case 0:
            // Exit 0 already means "at least one process matched"; a lost capture must not
            // downgrade that to "gone", which would relaunch profiles mid-install.
            guard let pid = output.trimmedOutput
                .split(whereSeparator: \.isWhitespace).first.flatMap({ Int32($0) })
            else { return .runningPIDUnknown }
            return .running(pid: pid)
        case 1: return .gone // pgrep reserves 1 for "no processes matched"
        default: return .unknown // usage/fatal error
        }
    }

    /// "Not known to be gone" — the reading a **wait** wants. Uncertainty resolves to
    /// *running* here because the costs are not symmetric: a wrong "gone" relaunches
    /// profiles into a live install and destroys it, while a wrong "running" only spends
    /// the caller's poll budget and ends in a message the user sees.
    public func isRunning() -> Bool {
        liveness() != .gone
    }

    /// "Known to be running" — the reading a **block** wants. A guard that refuses on
    /// uncertainty refuses forever, since nothing resolves an unhealthy probe: with `pgrep`
    /// broken, every Open, Restart and deep link in the app would be dead with no budget to
    /// run out. So an unknown fails *open* here, exactly opposite to ``isRunning()``.
    public func isConfirmedRunning() -> Bool {
        switch liveness() {
        case .running, .runningPIDUnknown: true
        case .gone, .unknown: false
        }
    }

    /// How long the installer has been running, or `nil` when it is not running (or its age
    /// can't be read — an unknown liveness included, since there is no pid to ask about).
    ///
    /// The age is the whole question a health check has: a swap is 3–5 s and even the
    /// pathological ones stayed under a minute, so an installer measured in *minutes* is not
    /// installing — it is waiting for profiles to close, which it will do indefinitely and
    /// silently.
    ///
    /// **`etime`, not `etimes`.** The seconds-only `etimes` keyword is a GNU/procps
    /// extension; Darwin's `ps` rejects it outright (`ps: etimes: keyword not found`, exit 1),
    /// which would have made this return `nil` forever and the diagnostic never fire. BSD
    /// `etime` formats as `[[dd-]hh:]mm:ss`, so it is parsed here.
    public func runningFor() -> TimeInterval? {
        guard case let .running(pid) = liveness() else { return nil }
        guard let output = try? runner.run(CoreConstants.psPath, ["-o", "etime=", "-p", String(pid)]),
              output.succeeded
        else { return nil }
        return Self.elapsedSeconds(fromETime: output.trimmedOutput)
    }

    /// Parse BSD `ps` elapsed time — `mm:ss`, `hh:mm:ss`, or `dd-hh:mm:ss`.
    /// Returns `nil` for anything that doesn't fit, so a format change degrades to "no
    /// reading" rather than to a wrong number.
    static func elapsedSeconds(fromETime text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let daySplit = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard daySplit.count <= 2 else { return nil }
        var days = 0.0
        if daySplit.count == 2 {
            guard let parsed = Double(daySplit[0]) else { return nil }
            days = parsed
        }
        let clock = daySplit.count == 2 ? daySplit[1] : daySplit[0]
        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard (2 ... 3).contains(parts.count) else { return nil }
        var clockSeconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            clockSeconds = clockSeconds * 60 + value
        }
        return days * 86400 + clockSeconds
    }

    /// Current size of ShipIt's `stderr` log, to be passed back to ``failureReason(since:)``.
    /// Zero when the log is missing — a log created later is then read from its start.
    public func stderrOffset() -> UInt64 {
        let attributes = try? fileManager.attributesOfItem(atPath: stderrPath)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// The failure ShipIt logged **after** `offset`, phrased for a person, or `nil` when it
    /// logged nothing recognizable (which includes the ordinary success path).
    ///
    /// Scanning only past `offset` is what makes the answer belong to *this* attempt: the
    /// log is append-only and never rotated, so its tail otherwise holds failures from days
    /// ago that would be reported as though they had just happened.
    /// Scanned backwards, and **a success ends the scan**. The log interleaves attempts, so a
    /// failure followed by a completed install is history, not a current problem: reporting
    /// the older failure would tell the user their last attempt didn't complete when it did.
    /// Whichever terminal line comes last is the answer.
    public func failureReason(since offset: UInt64) -> String? {
        guard let text = appendedText(since: offset) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            if line.contains(Self.successMarker) { return nil }
            if let reason = Self.reason(inLine: String(line)) { return reason }
        }
        return nil
    }

    /// What ShipIt logs when an install goes through.
    private static let successMarker = "Installation completed successfully"

    // MARK: - Internals

    /// Bytes appended to the log since `offset`, decoded as UTF-8.
    private func appendedText(since offset: UInt64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: stderrPath) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Map one ShipIt log line to a human-readable reason.
    ///
    /// The first two shapes are the ones this project actually produces: a Claude instance
    /// appearing mid-install (which is what a premature relaunch causes), and Squirrel
    /// exhausting its retry budget. Anything else recognisable is passed through verbatim
    /// rather than dropped — a reason we don't have prose for still beats "it didn't work".
    static func reason(inLine line: String) -> String? {
        if line.contains("running instances of the target app") || line.contains("App Still Running Error") {
            return "a Claude instance was running while ShipIt tried to swap the app"
        }
        if line.contains("Too many attempts to install") {
            return "ShipIt gave up after repeated failed attempts"
        }
        guard let range = line.range(of: "Installation error: ") else { return nil }
        return Self.condensed(String(line[range.upperBound...]))
    }

    /// Trim a raw ShipIt error to one readable sentence — its `NSError` dumps run to several
    /// hundred characters of nested `UserInfo`, which no alert can usefully show.
    private static func condensed(_ text: String) -> String? {
        let flattened = text
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else { return nil }
        guard flattened.count > maxReasonLength else { return flattened }
        return String(flattened.prefix(maxReasonLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let maxReasonLength = 180
}
