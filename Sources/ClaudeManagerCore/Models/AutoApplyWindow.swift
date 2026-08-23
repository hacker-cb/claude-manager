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
        /// The user hasn't turned it on. The default, deliberately.
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

        public init(
            enabled: Bool,
            applyInFlight: Bool,
            hasStagedUpdate: Bool,
            window: AutoApplyWindow,
            now: Date,
            idleSeconds: TimeInterval,
            minimumIdleSeconds: TimeInterval
        ) {
            self.enabled = enabled
            self.applyInFlight = applyInFlight
            self.hasStagedUpdate = hasStagedUpdate
            self.window = window
            self.now = now
            self.idleSeconds = idleSeconds
            self.minimumIdleSeconds = minimumIdleSeconds
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
        return .apply
    }
}
