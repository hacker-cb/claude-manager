import ClaudeManagerCore
import Foundation

/// How a check reports what it found.
///
/// Three answers rather than a flag, because the two manual paths differ in where the user is
/// looking. Settings has the status line in front of it, so the outcome reaching the *state*
/// is the answer, and an alert written from there would be presented by the main window's
/// modifier — a window that may not even be open, and that would then ambush the user with a
/// stale verdict hours later. The menu bar and the window's toolbar button have no such line,
/// so they take the alert as well. The schedule stays quiet: a laptop is offline all the time,
/// and a notice per closed lid is noise.
enum ClaudeUpdateAnnouncement {
    /// The scheduled check: the log, and nothing else.
    case silently
    /// A press beside the status line, which renders whatever the state becomes.
    case inTheStatusLine
    /// A press with no status line in view: the state, plus an alert in the window.
    case withAnAlert

    /// Whether the user asked for this check. The two manual cases record a failure in the
    /// state where the schedule deliberately does not.
    var isManual: Bool {
        self != .silently
    }

    var showsAnAlert: Bool {
        self == .withAnAlert
    }
}

/// The manual check, and how any check reports what it found. Split from
/// `AppModel+ClaudeUpdateCheck` — which owns the schedule, the request and the fetch — so
/// neither file outgrows its length budget.
extension AppModel {
    /// Check now because someone pressed a button, and say what came of it.
    ///
    /// Two things separate this from the scheduled path, and both are the point. It ignores
    /// the four-hourly throttle — a button that answers "not yet, come back at half past two"
    /// is not a button. And it reports its outcome: a background check that finds nothing is
    /// right to stay silent, but a press that changes nothing on screen is indistinguishable
    /// from one that did nothing at all, which is what an unreachable feed looked like for a
    /// whole day before this existed.
    func checkForClaudeUpdateNow(announcing: ClaudeUpdateAnnouncement = .withAnAlert) {
        guard managesClaudeUpdates else {
            // Presented directly rather than through `announce`, whose gate exists for answers
            // arriving *after* the feature was switched off — it would discard the one sentence
            // whose whole subject is that state, leaving the menu item to open a window and say
            // nothing.
            if announcing.showsAnAlert {
                presentInfo(
                    title: "Claude updates are switched off",
                    message: "Turn \u{201C}Let Claude Manager update Claude\u{201D} back on in Settings "
                        + "and Claude Manager will fetch new builds again."
                )
            }
            return
        }
        // Nothing to compare a release against. `isUpgrade` answers `false` for an absent or
        // unreadable installed version, so the feed's newest build reads as "no update" and the
        // check would end by calling a machine that cannot be updated at all up to date — while
        // stamping the success that keeps Doctor quiet about it.
        //
        // Recorded as a failure, not only announced: `.inTheStatusLine` shows no alert, so a
        // press in Settings would otherwise be answered by nothing at all.
        // Comparable, not merely present: `RealClaude.version()` hands back whatever the plist
        // holds, and an empty or non-numeric string reaches `isUpgrade` as an unreadable
        // baseline — false, the same answer it gives for "no newer build", which is how a
        // machine that cannot be compared at all came to be told it was up to date.
        guard let installed = realClaudeVersion,
              AvailableUpdate.isComparableVersion(installed)
        else {
            recordCheckFailure(
                "Claude Manager could not read a usable version from Claude.app, so there is "
                    + "nothing to compare a release against. Try Re-detect in Settings.",
                title: "Claude's version could not be read",
                announcing: announcing
            )
            return
        }
        // Both halves, and neither covers the other. `allowsCheck` is false for work in
        // flight: a download owning the cache, and a swap that would have the staging
        // directory rewritten under it while `installUpdate` moves it into `/Applications`. A
        // prepared build is *not* on that list — a press over one is exactly the case that has
        // to reach the feed, since what it wants to know is whether the offer it is looking at
        // is still the newest. `isCheckingClaudeUpdate` is the separate question of whether
        // one is already under way: an install runs in a task of its own, so the handle alone
        // would let a press through to stamp the throttle and then die, wordlessly, on
        // `refreshClaudeUpdate`'s busy guard — the "did I press it?" failure this exists to
        // remove.
        guard claudeUpdateState.allowsCheck, !isCheckingClaudeUpdate else {
            let answer = busyAnswer
            announce(announcing, title: answer.title, message: answer.message)
            return
        }
        startClaudeUpdateRefresh(announcing: announcing)
    }

    /// Why the press could not start a check, as a heading and a sentence.
    ///
    /// The heading matters as much as the body. Calling any of these "a check" is how a promise
    /// of a report gets made on behalf of work that never agreed to give one — and a build
    /// already prepared is not "working on it" at all: nothing is running, and the answer the
    /// press was after is on the screen already.
    ///
    /// The message deliberately never says "and it will tell you what it finds": the work in
    /// flight carries its own voice, and every non-manual starter passes `.silently` — the
    /// monitor tick, the activation observer, the restore that runs at launch.
    private var busyAnswer: (title: String, message: String) {
        // Only reachable while a check is already running: `allowsCheck` is true for a prepared
        // build now, so an otherwise idle `.ready` sends the press on to ask the feed like any
        // other state — which is the point, since what that press wants to know is whether this
        // offer is still the newest one.
        if case let .ready(verified) = claudeUpdateState {
            return (
                "Claude \(verified.version) is ready to install",
                "It has been downloaded and verified, and a check for anything newer is running "
                    + "right now. Press Install when you are ready for your profiles to close."
            )
        }
        guard claudeUpdateState.allowsCheck else {
            // `.downloading` and `.installing` — the state says it better than this could.
            return (
                "Already working on it",
                claudeUpdateState.statusLine(lastSuccess: lastClaudeUpdateSuccess)
            )
        }
        if claudeUpdateCleanupTask != nil {
            return (
                "Already working on it",
                "Claude Manager is still clearing the build it had downloaded. Try again in a "
                    + "moment."
            )
        }
        return (
            "Already working on it",
            "A check is already running. Give it a moment, and press again if nothing appears."
        )
    }

    /// Say something, if this check's voice carries that far — see `ClaudeUpdateAnnouncement`
    /// for why the settings path deliberately says nothing here.
    func announce(
        _ voice: ClaudeUpdateAnnouncement, title: String, message: String
    ) {
        guard voice.showsAnAlert else { return }
        // The same gate `publishClaudeUpdateState` applies to the state. Switching the feature
        // off cancels the request mid-flight, and the answer that arrives a moment later — "up
        // to date" as much as a failure — would then be an alert about a feature the user has
        // just turned off. `Task.isCancelled` reads false outside a task, so the synchronous
        // callers are unaffected.
        guard !Task.isCancelled, managesClaudeUpdates else { return }
        presentInfo(title: title, message: message)
    }

    /// What a failed check leaves behind, which depends on who asked for it.
    ///
    /// The schedule leaves nothing. A press has to survive being answered, so `.failed` puts
    /// the reason in the toolbar button, the status line and the menu — but **only over
    /// `.idle`**.
    /// `.available` and `.ready` each carry a control of their own, Download and Install, and a
    /// build already downloaded and verified stays installable whether or not the feed can be
    /// reached: overwriting that state takes the button away and strands the very bytes the
    /// press was reaching for.
    func reportFailedCheck(_ error: Error, announcing: ClaudeUpdateAnnouncement) {
        guard announcing.isManual else { return }
        // Cancellation is not a failure to report. Switching the feature off cancels the task
        // mid-request, and while `publishClaudeUpdateState` refuses to speak for a feature that
        // is off, an alert has no such gate — the user would turn the thing off and be told the
        // release service is unreachable.
        guard !Task.isCancelled, managesClaudeUpdates else { return }
        // No "could not be reached" prefix: `UpdateFeed.Failure` also covers a service that
        // answered and was refused — an unexpected status, a payload this version cannot read,
        // an insecure download URL — and prefixing those with a connectivity claim sends the
        // reader to check their wifi over a sentence saying the server replied.
        recordCheckFailure(
            Self.describeUpdateFailure(error),
            title: "Could not check for updates",
            announcing: announcing
        )
    }

    /// Put one failed check everywhere it has to be readable.
    ///
    /// Three surfaces, and each covers a case the others cannot. The **recorded reason** is the
    /// only one that survives `.available` and `.ready`, which keep their own control (Download,
    /// Install) and must not lose it to a feed that went quiet. The **state** is what the
    /// toolbar button and the menu render, so it takes the reason over `.idle` and over an
    /// earlier `.failed` —
    /// a retry that fails differently has to say the new one, not leave the first standing. And
    /// the **alert** is for the presses with no status line in view.
    private func recordCheckFailure(
        _ reason: String, title: String, announcing: ClaudeUpdateAnnouncement
    ) {
        setClaudeUpdateCheckFailure(reason)
        switch claudeUpdateState {
        case .idle, .failed: publishClaudeUpdateState(.failed(reason: reason))
        case .available, .downloading, .installing, .ready: break
        }
        announce(announcing, title: title, message: reason)
    }
}
