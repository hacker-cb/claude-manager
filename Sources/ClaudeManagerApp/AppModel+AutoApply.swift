import AppKit
import ClaudeManagerCore
import Foundation

/// Applying a staged Claude update unattended, inside a window the user nominated.
///
/// This exists because the alternative is Claude's own enforcement: it restarts the default
/// profile by itself once an update has been pending long enough, at a moment chosen to be
/// unobserved. That restart cannot be disabled and it can't be moved — so the only way to
/// stop it being a surprise is to have applied the update before it comes due, at a time the
/// user picked.
///
/// **Nothing here decides whether a profile may be closed.** That question has no answer from
/// outside the process — measured: power assertions don't track agent work, process-tree CPU
/// measures UI rendering, and a session process idles near 1 % whether it is working or not.
/// Claude answers it, by vetoing its own quit while a session runs, and `applyStagedUpdateToAll`
/// treats that refusal as an abort and restores everything it closed. This file only chooses
/// *when to ask*.
///
/// It also asks **quietly**: the apply is invoked with `surfacingFailures: false`, because the
/// interactive path fights for attention on failure — it reopens the window and activates the
/// app — and doing that at 04:30 because a profile was busy would be the same surprise this
/// feature exists to remove. Unattended failures go to the log and to Doctor, which wait to be
/// read.
extension AppModel {
    /// The banner's enabling offer: whether to show it, and the wait to quote.
    struct AutoApplyOffer: Equatable {
        /// The version the banner is showing. Carried so a decline is recorded against what
        /// the user actually saw — a background probe can move `stagedUpdate` on before the
        /// offer is recomputed, and keying off that would suppress an offer never shown.
        let stagedVersion: String
        let waitDescription: String
        let windowText: String
    }

    // MARK: - Settings

    /// Backed by `defaults` rather than `@Published` (an extension can't declare one), so
    /// the change notification is sent by hand — without it SwiftUI never re-evaluates the
    /// settings section and the window pickers stay hidden after the toggle is switched on.
    var autoApplyEnabled: Bool {
        get { defaults.bool(forKey: PreferenceKeys.autoApplyStagedUpdate) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: PreferenceKeys.autoApplyStagedUpdate)
        }
    }

    /// The nominated window. Unset reads as the suggested night-time one, so switching the
    /// feature on doesn't require also picking a time before it means anything.
    var autoApplyWindow: AutoApplyWindow {
        get {
            guard let start = defaults.object(forKey: PreferenceKeys.autoApplyWindowStart) as? Int,
                  let end = defaults.object(forKey: PreferenceKeys.autoApplyWindowEnd) as? Int
            else { return .suggested }
            return AutoApplyWindow(startMinutes: start, endMinutes: end)
        }
        set {
            objectWillChange.send() // same reason as the toggle above
            defaults.set(newValue.startMinutes, forKey: PreferenceKeys.autoApplyWindowStart)
            defaults.set(newValue.endMinutes, forKey: PreferenceKeys.autoApplyWindowEnd)
            // The offer quotes this window; leaving the cache alone would have the banner and
            // its confirmation naming a schedule the acceptance no longer uses.
            refreshAutoApplyOffer()
        }
    }

    /// Window ends as separate bindable minute values, for the settings pickers. Writing
    /// either one re-normalises through `AutoApplyWindow`, so an out-of-range value can't be
    /// stored by going around the model.
    var autoApplyWindowStart: Int {
        get { autoApplyWindow.startMinutes }
        set {
            autoApplyWindow = AutoApplyWindow(startMinutes: newValue, endMinutes: autoApplyWindow.endMinutes)
        }
    }

    var autoApplyWindowEnd: Int {
        get { autoApplyWindow.endMinutes }
        set { autoApplyWindow = AutoApplyWindow(
            startMinutes: autoApplyWindow.startMinutes,
            endMinutes: newValue
        ) }
    }

    /// When an unattended attempt last failed, per staged version. One entry at a time: a
    /// newly staged version deserves its own attempt rather than inheriting a back-off.
    var autoApplyLastFailure: [String: Date] {
        get {
            guard let raw = defaults.dictionary(forKey: PreferenceKeys.autoApplyLastFailure)
            else { return [:] }
            return raw.compactMapValues { value in
                guard let seconds = value as? Double else { return nil }
                return Date(timeIntervalSince1970: seconds)
            }
        }
        set {
            defaults.set(
                newValue.mapValues(\.timeIntervalSince1970), forKey: PreferenceKeys.autoApplyLastFailure
            )
        }
    }

    /// Recompute the banner offer. Called from `refresh()` — never from a view body, where
    /// the file reads behind `stagedUpdateDeadline` would land on the main thread on every
    /// layout pass — and again from every path that changes one of its inputs, since a cached
    /// answer that outlives its inputs is a button that looks broken.
    func refreshAutoApplyOffer(now: Date = Date()) {
        guard let version = stagedUpdate?.stagedVersion, let deadline = stagedUpdateDeadline else {
            setAutoApplyOffer(nil)
            return
        }
        let waited = deadline.waited(asOf: now)
        guard AutoApplyDecision.shouldOfferEnabling(
            alreadyEnabled: autoApplyEnabled,
            dismissed: dismissedAutoApplyOffer.contains(version),
            waited: waited
        ) else {
            setAutoApplyOffer(nil)
            return
        }
        setAutoApplyOffer(AppModel.AutoApplyOffer(
            stagedVersion: version,
            waitDescription: Self.waitDescription(waited),
            // The window the offer *would actually use*, resolved here rather than at
            // acceptance. An empty stored window (start == end) admits no time at all, so
            // accepting it would enable a permanently inert feature — it is replaced with the
            // suggested night. Resolving that after the user has read "between 04:00–04:00"
            // and agreed is precisely the silent substitution this offer promises not to make.
            windowText: effectiveAutoApplyWindow.displayText
        ))
    }

    /// The window an acceptance would install: the stored one, unless it is empty.
    var effectiveAutoApplyWindow: AutoApplyWindow {
        let window = autoApplyWindow
        return window.startMinutes == window.endMinutes ? .suggested : window
    }

    /// "over a day" / "3 days", for the offer's first sentence.
    ///
    /// `Int(exactly:)` rather than a plain conversion: `waited` comes from a date decoded out
    /// of `UserDefaults` with no range check, and a corrupt or hand-edited entry (`1e300`)
    /// would trap on the conversion — crashing the app from a banner render. Same hazard
    /// `ManagedConfigWriter.integer` already guards. The sub-day branch exists only for that
    /// fallback and for callers other than the offer, which never asks below a full day.
    static func waitDescription(_ waited: TimeInterval) -> String {
        guard let hours = Int(exactly: (waited / 3600).rounded(.down)) else { return "a while" }
        guard hours >= 24 else { return "\(hours) hours" }
        let days = hours / 24
        return days == 1 ? "over a day" : "\(days) days"
    }

    /// Staged versions whose enabling offer the user has declined.
    var dismissedAutoApplyOffer: Set<String> {
        get { Set(defaults.stringArray(forKey: PreferenceKeys.dismissedAutoApplyOffer) ?? []) }
        set { defaults.set(Array(newValue), forKey: PreferenceKeys.dismissedAutoApplyOffer) }
    }

    /// Decline the offer for the version the banner is **actually showing**.
    ///
    /// Keyed off the offer rather than `stagedUpdate`, which a background probe can have
    /// already moved on: recording the decline against a version the user was never shown
    /// would suppress an offer that never appeared.
    func dismissAutoApplyOffer() {
        guard let version = autoApplyOffer?.stagedVersion else { return }
        dismissedAutoApplyOffer = dismissedAutoApplyOffer.union([version])
        setAutoApplyOffer(nil) // the input changed; don't leave the line on screen for a minute
    }

    /// Accept the offer: switch unattended applying on, with the window that was shown.
    ///
    /// This is the whole point of offering rather than defaulting: the user turning it on is
    /// the same event as the app being allowed to close their profiles, instead of two
    /// independent ones where the second can happen without the first having landed.
    func enableAutoApplyFromOffer() {
        autoApplyWindow = effectiveAutoApplyWindow // no-op unless the stored one was empty
        Log.autoApply.info("enabled from the stuck-update offer")
        autoApplyEnabled = true
        setAutoApplyOffer(nil) // it is on now — the banner must stop offering it
    }

    // MARK: - The pass

    /// Attempt the apply if every precondition holds; otherwise return the condition that
    /// stopped it. The decision itself lives in Core (`AutoApplyDecision`) under test — this
    /// only gathers the inputs and acts on the verdict.
    @discardableResult
    func runAutoApplyPass(now: Date = Date(), idleSeconds: TimeInterval? = nil) async -> AutoApplyDecision {
        let decision = AutoApplyDecision.decide(AutoApplyDecision.Inputs(
            enabled: autoApplyEnabled,
            applyInFlight: isApplyingStagedUpdate,
            hasStagedUpdate: stagedUpdate != nil,
            window: autoApplyWindow,
            now: now,
            idleSeconds: idleSeconds ?? Self.systemIdleSeconds(),
            minimumIdleSeconds: Self.minimumIdleSeconds,
            lastFailedAttempt: stagedUpdate.flatMap { autoApplyLastFailure[$0.stagedVersion] }
        ))
        guard decision == .apply, let version = stagedUpdate?.stagedVersion else { return decision }
        let windowText = autoApplyWindow.displayText
        Log.autoApply.info("applying inside window \(windowText, privacy: .public)")
        await applyStagedUpdate(surfacingFailures: false)
        // Still staged afterwards means the attempt did not go through — most often a profile
        // vetoed its quit because it was working. Record it so the back-off holds: retrying on
        // the next tick would close and reopen every *other* profile once a minute, and
        // re-prompt the busy one, for the rest of the window.
        if stagedUpdate?.stagedVersion == version {
            autoApplyLastFailure = [version: now]
            Log.autoApply.info("attempt did not complete — backing off")
        } else {
            autoApplyLastFailure = [:]
        }
        return decision
    }

    /// How long the machine must have been untouched. Ten minutes matches what Claude's own
    /// updater waits for before its forced restart — the same judgement about "the user has
    /// stepped away", and no reason for ours to be twitchier.
    static let minimumIdleSeconds: TimeInterval = 600

    /// Re-probe the staged update without a full `refresh()`.
    ///
    /// Needed because the pass runs from the background tick, where `refresh()` deliberately
    /// does not: it sweeps the process table and every launcher, which is exactly what a
    /// backgrounded menu-bar app should not do every minute. `stagedUpdate` would otherwise
    /// be whatever the last foreground refresh saw — quite possibly hours stale, and possibly
    /// nil when an update has since been staged, so the pass would never fire.
    ///
    /// Not routed through `perform`: that surfaces an alert when Claude can't be located, and
    /// an unattended background probe must never raise a dialog nobody is there to read.
    func refreshStagedUpdateInBackground() async {
        guard let real = realClaude, let config = currentConfiguration() else { return }
        let staged = await Task.detached {
            ProfileStore(realClaude: real, configuration: config).stagedUpdate()
        }.value
        setStagedUpdate(staged)
        recordStagedUpdateSighting()
        // The staged version may have changed under the offer; recompute rather than leaving
        // the banner quoting a wait that belongs to a version no longer staged.
        refreshAutoApplyOffer()
    }

    /// Seconds since the last human input, across the whole session.
    static func systemIdleSeconds() -> TimeInterval {
        // Prefer CoreGraphics' all-input sentinel: it covers tablet input and long drags an
        // enumerated subset misses, and missing one is not harmless — if the user's only
        // recent input is an unlisted event, every sampled timestamp exceeds the threshold
        // and the pass fires while the Mac is being used. Guarded, not force-unwrapped: it is
        // undocumented, reached through a failable initializer, and this runs unattended.
        if let anyInput = CGEventType(rawValue: ~0) {
            return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        }
        // Fallback for a build where that sentinel stops being valid. Narrower by
        // construction, so it can only ever over-report idleness.
        let inputTypes: [CGEventType] = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .mouseMoved, .scrollWheel, .tabletPointer, .tabletProximity
        ]
        return inputTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            // Zero — "input just happened" — is the conservative answer to an empty result:
            // it skips the pass rather than acting on an unknown.
            .min() ?? 0
    }
}
