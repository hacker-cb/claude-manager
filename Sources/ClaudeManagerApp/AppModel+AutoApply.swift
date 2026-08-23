import AppKit
import ClaudeManagerCore
import Foundation
import UserNotifications

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
    // MARK: - Settings

    /// **On by default.** With it off, a machine running clones never installs a Claude
    /// update at all: the swap stays blocked, and Claude's own enforcement restarts the
    /// default profile every ~72 h to no effect, re-downloading the bundle each round. A
    /// default that leaves the product's core scenario permanently broken is the wrong
    /// default, even though this one closes windows — `announceAutoApplyDefaultIfNeeded` is
    /// what keeps that from arriving as a surprise.
    ///
    /// `object(forKey:)` rather than `bool(forKey:)`: the latter reads an unset key as
    /// `false`, which would make "never configured" indistinguishable from "explicitly
    /// turned off" and silently override the choice of anyone who had turned it off.
    ///
    /// Backed by `defaults` rather than `@Published` (an extension can't declare one), so
    /// the change notification is sent by hand — without it SwiftUI never re-evaluates the
    /// settings section and the window pickers stay hidden after the toggle is switched on.
    var autoApplyEnabled: Bool {
        get { defaults.object(forKey: PreferenceKeys.autoApplyStagedUpdate) as? Bool ?? true }
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

    /// Whether the user has set the toggle themselves, either way. Distinct from its
    /// *value*: what matters for the announcement is whether a choice was ever made.
    var autoApplyWasConfigured: Bool {
        defaults.object(forKey: PreferenceKeys.autoApplyStagedUpdate) != nil
    }

    /// Tell the user once that unattended applying is now on, and where to change it.
    ///
    /// Called at launch. The feature reaches existing installs through a Sparkle
    /// auto-update, so without this their profiles would start closing overnight with no
    /// explanation — precisely the experience this whole area of the app exists to prevent,
    /// only caused by us instead of Claude. Skipped for anyone who already set the toggle:
    /// their preference stands, and calling it "a new default" would be untrue.
    func announceAutoApplyDefaultIfNeeded() async {
        guard AutoApplyDecision.shouldAnnounceDefault(
            alreadyAnnounced: defaults.bool(forKey: PreferenceKeys.autoApplyDefaultAnnounced),
            userSetTheToggle: autoApplyWasConfigured
        ) else { return }
        // Mark it first. A notification that fails to post is not worth repeating at every
        // launch forever; the settings pane says the same thing, permanently.
        defaults.set(true, forKey: PreferenceKeys.autoApplyDefaultAnnounced)

        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude updates now install overnight"
        content.body = "Claude Manager applies a downloaded Claude update between "
            + "\(autoApplyWindow.displayText), when your Mac is idle — quitting your profiles "
            + "and reopening them. Change the window or turn it off in Settings → Claude updates."
        try? await center.add(UNNotificationRequest(
            identifier: "claude-auto-apply-default", content: content, trigger: nil
        ))
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
