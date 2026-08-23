import Foundation

/// The daily window in which Claude Manager may apply a staged Claude update on its own.
///
/// The apply closes every profile and reopens it, so *when* it happens is the whole design.
/// A window the user nominates is the honest form of that choice: predictable, explicable
/// after the fact ("it was 04:30, which is what you asked for"), and impossible to confuse
/// with the app deciding for itself.
///
/// **This is a scheduling question, not a safety one.** Nothing here decides whether a
/// profile may be closed — Claude answers that by vetoing its own quit when a session is
/// working, and `applyStagedUpdateToAll` treats the refusal as an abort. What the window
/// buys is that the attempt happens at a moment the user picked rather than mid-afternoon.
public struct AutoApplyWindow: Equatable, Sendable, Codable {
    /// Minutes since midnight, local time.
    public let startMinutes: Int
    public let endMinutes: Int

    /// The default suggestion when the feature is switched on: 04:00–06:00. Late enough that
    /// the machine is usually idle, early enough that the profiles are back before morning.
    public static let suggested = AutoApplyWindow(startMinutes: 4 * 60, endMinutes: 6 * 60)

    public init(startMinutes: Int, endMinutes: Int) {
        self.startMinutes = AutoApplyWindow.wrapped(startMinutes)
        self.endMinutes = AutoApplyWindow.wrapped(endMinutes)
    }

    /// Whether `date`'s local time-of-day falls inside the window.
    ///
    /// A window whose end is *before* its start crosses midnight (22:00–02:00), which is
    /// exactly the shape a night-time window tends to take — so it is supported rather than
    /// rejected, and it is the case a naive `start...end` range gets silently wrong.
    /// Start-inclusive, end-exclusive, so two adjacent windows can't both claim one minute.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return false }
        let nowMinutes = hour * 60 + minute
        // An empty window (start == end) admits nothing; the alternative — admitting the
        // whole day — would turn a mis-set window into "apply at any moment", which is the
        // surprise this feature exists to avoid.
        guard startMinutes != endMinutes else { return false }
        if startMinutes < endMinutes {
            return nowMinutes >= startMinutes && nowMinutes < endMinutes
        }
        return nowMinutes >= startMinutes || nowMinutes < endMinutes
    }

    /// A window that admits no time at all. Reachable from the settings pickers, which bind
    /// each end independently — and a feature that is switched on yet can never act is worse
    /// than one that is off, because nothing says so. Callers surface it rather than silently
    /// substituting a different window.
    public var isEmpty: Bool {
        startMinutes == endMinutes
    }

    /// `HH:mm–HH:mm`, for the settings summary and the log line that explains an apply.
    public var displayText: String {
        "\(Self.clock(startMinutes))–\(Self.clock(endMinutes))"
    }

    private static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// Fold any integer onto a real minute of the day, so a stored value from a future build
    /// (or a hand-edited preference) can't produce a window that never opens.
    private static func wrapped(_ minutes: Int) -> Int {
        let day = 24 * 60
        return ((minutes % day) + day) % day
    }
}

/// Whether an unattended apply may run right now, and if not, which condition stopped it.
///
/// A verdict type rather than a chain of `guard`s inside the app layer, for one reason: this
/// runs while nobody is watching. "It silently did nothing" is the hardest failure to
/// diagnose after the fact, so the decision is a value that can be logged and asserted on.
public enum AutoApplyDecision: Equatable, Sendable {
    case apply
    case skip(Reason)

    public enum Reason: Equatable, Sendable {
        /// Unattended applying is not enabled. Core sees only the `enabled` input and does
        /// not know the app layer's default, so this says nothing about *why*.
        case disabled
        /// Outside the nominated window.
        case outsideWindow
        /// Nothing to install.
        case nothingStaged
        /// An apply is already running — never start a second one over a live swap.
        case applyInFlight
        /// Someone is at the keyboard. A courtesy check, not a safety one: it says nothing
        /// about an autonomous session, which is Claude's veto's job to catch.
        case userIsPresent
        /// A recent attempt on this same version did not go through — most often because a
        /// profile was working and vetoed its own quit. Backing off is the whole point:
        /// without it the tick retries every minute for the rest of the window, and each
        /// retry closes and reopens every *other* profile and re-prompts the busy one.
        case backingOffAfterFailure
    }

    /// Everything the decision reads, gathered so the app layer can't transpose two
    /// same-typed arguments at the call site — `enabled` and `applyInFlight` next to each
    /// other in a parameter list is exactly the swap nobody notices.
    public struct Inputs: Equatable, Sendable {
        public var enabled: Bool
        public var applyInFlight: Bool
        public var hasStagedUpdate: Bool
        public var window: AutoApplyWindow
        public var now: Date
        public var idleSeconds: TimeInterval
        public var minimumIdleSeconds: TimeInterval
        /// When an attempt on the *currently staged* version last failed, if one did.
        public var lastFailedAttempt: Date?

        public init(
            enabled: Bool,
            applyInFlight: Bool,
            hasStagedUpdate: Bool,
            window: AutoApplyWindow,
            now: Date,
            idleSeconds: TimeInterval,
            minimumIdleSeconds: TimeInterval,
            lastFailedAttempt: Date? = nil
        ) {
            self.enabled = enabled
            self.applyInFlight = applyInFlight
            self.hasStagedUpdate = hasStagedUpdate
            self.window = window
            self.now = now
            self.idleSeconds = idleSeconds
            self.minimumIdleSeconds = minimumIdleSeconds
            self.lastFailedAttempt = lastFailedAttempt
        }
    }

    /// Order matters only for what gets *reported*, since any one skip is enough. Cheap and
    /// definitive conditions come first, so the reason surfaced is the most informative one:
    /// "you haven't enabled this" beats "the Mac isn't idle" when both are true.
    public static func decide(_ inputs: Inputs, calendar: Calendar = .current) -> AutoApplyDecision {
        guard inputs.enabled else { return .skip(.disabled) }
        guard !inputs.applyInFlight else { return .skip(.applyInFlight) }
        guard inputs.hasStagedUpdate else { return .skip(.nothingStaged) }
        guard inputs.window.contains(inputs.now, calendar: calendar) else { return .skip(.outsideWindow) }
        guard inputs.idleSeconds >= inputs.minimumIdleSeconds else { return .skip(.userIsPresent) }
        // A timestamp in the *future* — a clock moved back, restored preferences from another
        // machine — would make the elapsed time negative and hold the back-off until the wall
        // clock caught up, skipping windows for days. Treated as no record at all: a bad clock
        // should cost at most one extra attempt, never a silently disabled feature.
        let sinceFailure = inputs.lastFailedAttempt.map { inputs.now.timeIntervalSince($0) }
        guard sinceFailure.map({ $0 < 0 || $0 >= Self.retryBackoff }) ?? true else {
            return .skip(.backingOffAfterFailure)
        }
        return .apply
    }

    /// Whether to offer turning unattended applying on, given how long the update has been
    /// stuck behind open profiles.
    ///
    /// The offer exists because the feature is **off by default**, and that default has a real
    /// cost: a Mac running clones never installs a Claude update by itself, while Claude's own
    /// enforcement restarts the default profile every ~72 h to no effect. Flipping the default
    /// instead was tried and rejected (see `DECISIONS.md`) — the short version is that consent
    /// and the action it licenses have to be one event, not two independent ones.
    ///
    /// Timing is the whole design. Offering the moment an update is downloaded would be noise:
    /// most waits end within minutes of the user seeing the banner and clicking Apply. Offering
    /// once it has been stuck past ``stuckThreshold`` means the suggestion arrives with the
    /// evidence for it already on screen.
    /// `answered` is the user having settled the question for this version — by declining, or
    /// by reaching for the Settings toggle, which answers it either way. Without it the offer
    /// would reappear on every launch for the rest of the update's life — and the population
    /// this targets is exactly the one whose update *never* applies, so "it goes away when the
    /// update installs" is no answer for them.
    public static func shouldOfferEnabling(
        alreadyEnabled: Bool,
        answered: Bool,
        waited: TimeInterval
    ) -> Bool {
        !alreadyEnabled && !answered && waited >= stuckThreshold
    }

    /// How long an update must have been waiting before enabling is suggested.
    ///
    /// **A full day**, not twelve hours. The offer's premise is "this could already have been
    /// installed for you", and only a whole day makes that true whatever time the update
    /// arrived: twelve hours from a 07:00 sighting is 19:00 — no night has passed, and a
    /// night-time window has not come round even once. Twenty-four guarantees the user's
    /// window elapsed regardless of where in the day the clock started.
    public static let stuckThreshold: TimeInterval = 24 * 3600

    /// How long to wait after a failed unattended attempt before trying that same staged
    /// version again.
    ///
    /// The failure this is sized for is a profile refusing to quit because it is working —
    /// which the user is not necessarily around to resolve. Retrying on the next tick would
    /// close and reopen every *other* profile once a minute for the rest of the window, and
    /// re-prompt the busy one each time; six hours puts the next attempt in the following
    /// night's window instead. A newly staged version clears the record and starts fresh, so
    /// this never delays a genuinely different update.
    public static let retryBackoff: TimeInterval = 6 * 3600
}
