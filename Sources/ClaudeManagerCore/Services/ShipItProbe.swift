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

    /// True while a ShipIt process for this bundle is alive — **and true again whenever the
    /// probe cannot tell**.
    ///
    /// Matched on the executable name plus the job label ShipIt carries as its first
    /// argument (`…/Resources/ShipIt com.anthropic.claudefordesktop.ShipIt …`), so another
    /// app's updater — VS Code and GitKraken ship the same Squirrel binary — never counts
    /// as ours.
    ///
    /// Only `pgrep`'s exit **1** means "nothing matched"; 2 is a usage error and 3 a fatal
    /// one, and a failure to spawn it at all has no exit code. Folding those into `false`
    /// would answer "the installer is gone" for what is really "I don't know", and the
    /// caller relaunches profiles on that answer — mid-install, which is the one thing that
    /// destroys the swap. The costs are not symmetric: an unknown read as *running* only
    /// spends the caller's budget and ends in a `swapStillInstalling` the user is told
    /// about, so uncertainty resolves that way.
    public func isRunning() -> Bool {
        let pattern = "/ShipIt " + PathUtils.regexEscaped(bundleID) + "\\.ShipIt"
        guard let output = try? runner.run(CoreConstants.pgrepPath, ["-f", pattern]) else {
            return true // couldn't even run the probe — don't call that "gone"
        }
        switch output.exitCode {
        case 0: return !output.trimmedOutput.isEmpty
        case 1: return false // pgrep reserves 1 for "no processes matched"
        default: return true // usage/fatal error — unknown, so assume it is still working
        }
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
    public func failureReason(since offset: UInt64) -> String? {
        guard let text = appendedText(since: offset) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            if let reason = Self.reason(inLine: String(line)) { return reason }
        }
        return nil
    }

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
