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
extension AppModel {
    // MARK: - Settings

    var autoApplyEnabled: Bool {
        get { defaults.bool(forKey: PreferenceKeys.autoApplyStagedUpdate) }
        set { defaults.set(newValue, forKey: PreferenceKeys.autoApplyStagedUpdate) }
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
            minimumIdleSeconds: Self.minimumIdleSeconds
        ))
        guard decision == .apply else { return decision }
        let windowText = autoApplyWindow.displayText
        Log.autoApply.info("applying inside window \(windowText, privacy: .public)")
        await applyStagedUpdate()
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

    /// Seconds since the last human input event, across the whole session.
    static func systemIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)
    }
}
