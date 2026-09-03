import Foundation

/// Which windows a piece of work is about to spend — the one axis the overview ranks along.
///
/// Deliberately **not** named after a model. The per-model weekly window's model is *data*
/// (`UsageLimit.scopeModelName`, read from `scope.model.display_name`, which changed from
/// "Sonnet" to "Fable" mid-development), and a case called `.fable` would hard-code the single
/// thing this codebase has decided never to hard-code. The words a surface prints come from
/// `UsageOverview.modeLabel(_:accounts:)`, which reads the snapshots — so the page says "Fable
/// work" today and says whatever the server reports tomorrow, with no build in between.
///
/// `String`-backed so the app layer can persist the user's choice without a second mapping.
public enum WorkMode: String, Codable, Sendable, CaseIterable {
    /// Work on a model that carries its own weekly window — that window counts too.
    case scopedModel
    /// Work that spends only the windows every model shares.
    case otherWork
}

/// Why a candidate sits where it does. The first three are *rankable* positions on one scale
/// (headroom); the rest are reasons an account is out of the running altogether.
///
/// Gated states carry no payload: the window that caused them travels in
/// `UsageCandidate.gatingLimit`, which keeps this enum a plain ordering key and leaves one place
/// for a surface to read the figure from.
public enum CandidateState: Sendable, Equatable, CaseIterable {
    /// Well ahead of the week — the unspent budget is about to expire, so spending it is free.
    case spend
    /// Spending at roughly the rate the week elapses.
    case onPace
    /// Spending faster than the week elapses; this account runs out before its reset.
    case burningFast
    /// Usable, but no live clock behind the window that binds — either none was reported, or the
    /// one that was has already passed. Kept apart from `onPace`, which asserts a rate this case
    /// does not know, and worded for both causes rather than only the first.
    case paceUnknown
    /// The 5-hour window is nearly full. A gate, not a budget — it frees itself within hours.
    case sessionNearlyFull
    /// A counted window is one the app would paint red — our threshold, or the server's own
    /// `severity`, whichever is more severe (`UsageLimit.displaySeverity`).
    case nearlyOut
    /// A counted window is exhausted; nothing can be spent here until it resets.
    case out
    /// The binding needs a person — a sign-in, or a keychain authorization.
    case needsAttention
    /// Tracked, but nothing has been read for it yet.
    case noData

    /// Ordering lane. Lower sorts first, and only lane 0 is a *ranking* — everything below it
    /// is a reason to be out of the running, ordered by how much is known about when it stops
    /// being one.
    ///
    /// `paceUnknown` sits below the two dated constraints on purpose. It is not gated, but it is
    /// the state in which nothing can be vouched for — a window that rolled over leaves the
    /// account's current standing unread — and a list answering "where should work go" is more
    /// use with a profile that is briefly blocked and says exactly when it frees than with one
    /// nobody can speak for. `out` still sits below it: that one is known to be spent.
    var order: Int {
        switch self {
        case .spend, .onPace, .burningFast: 0
        case .sessionNearlyFull: 1
        case .nearlyOut: 2
        case .paceUnknown: 3
        case .out: 4
        case .needsAttention: 5
        case .noData: 6
        }
    }

    /// Whether this state is a *rated* position — a budget measured against a clock — rather
    /// than a constraint or an absence of information. This is what `canLead` gates on, so a
    /// state that cannot be rated cannot become the answer.
    public var isUsable: Bool {
        order == 0
    }
}

/// One account, assessed for the question "should I take work here now?".
///
/// It carries the whole `AccountUsage` rather than a copy of its parts: every surface that draws
/// a candidate also wants the login, the binding fan-out and the raw windows, and re-deriving
/// those from a flattened candidate is how two surfaces come to disagree about one account.
public struct UsageCandidate: Sendable, Equatable, Identifiable {
    public var account: AccountUsage
    public var state: CandidateState
    /// Unspent share of the binding weekly window **minus** the share of the week still to run.
    /// Positive means the budget outpaces the clock — spend it, because a weekly window's
    /// leftovers do not roll over. Nil when no counted weekly window reported a reset time, so
    /// there is no clock to compare against.
    public var headroom: Double?
    /// The counted weekly window that actually constrains this account — the one with the least
    /// headroom, not the fullest — and the figure the copy quotes.
    public var bindingWeekly: UsageLimit?
    /// The reset `headroom` was measured against: the binding window's own, and nil where that
    /// window had no live clock of its own.
    ///
    /// Carried rather than re-derived because the two consumers disagreed the moment they each
    /// looked it up — the pace was computed one way and the sentence explaining it another, so a
    /// row could read "use it or lose it" with the countdown behind it silently dropped.
    public var weeklyResetsAt: Date?
    /// The window that put this candidate out of the running, for a gated state.
    public var gatingLimit: UsageLimit?
    /// When that window lets go — **only while that is still ahead**.
    ///
    /// Normalized once, here, rather than read off the gating limit wherever it is needed: a
    /// retained snapshot can carry a reset that has already passed, and a past date is not an
    /// earlier return but an unknown one. Left un-normalized it sorted such a candidate ahead of
    /// every account known to come back soon, while the copy and `soonestReturn` were separately
    /// careful to ignore it — three readings of one field, two of them right.
    public var freesAt: Date?
    public init(
        account: AccountUsage,
        state: CandidateState,
        headroom: Double?,
        bindingWeekly: UsageLimit?,
        weeklyResetsAt: Date?,
        gatingLimit: UsageLimit?,
        freesAt: Date?
    ) {
        self.account = account
        self.state = state
        self.headroom = headroom
        self.bindingWeekly = bindingWeekly
        self.weeklyResetsAt = weeklyResetsAt
        self.gatingLimit = gatingLimit
        self.freesAt = freesAt
    }

    /// Whether this candidate may be *the answer*: usable, current, and with a clock behind it.
    ///
    /// Derived rather than stored. Every branch that built it computed exactly this, and a
    /// stored copy is a second statement of the rule that can fall out of step with the state
    /// beside it — a gated row asserting it may lead is not a state worth being able to express.
    public var canLead: Bool {
        state.isUsable && isCurrent && headroom != nil
    }

    public var id: String {
        account.identity.uuid
    }

    /// Whether the figures behind this candidate are current. Only a `.fresh` account is quoted
    /// as an instruction; everything else is shown with its state beside it.
    public var isCurrent: Bool {
        account.state == .fresh
    }
}

/// The ranked answer to "where should work go now", for one `WorkMode`.
///
/// A pure value: `rank` takes accounts and a clock and returns this. No I/O, no main actor, no
/// stored state — which is what lets `swift test` cover every rule in it, and what keeps the
/// page and the menu bar drawing one decision instead of two similar ones.
public struct UsageOverview: Sendable, Equatable {
    public var candidates: [UsageCandidate]
    public var mode: WorkMode

    public init(candidates: [UsageCandidate], mode: WorkMode) {
        self.candidates = candidates
        self.mode = mode
    }

    /// The account to take work to, or nil when nothing is in a position to be recommended.
    /// Nil is a real answer — a fleet that is entirely gated, stale or signed out has no
    /// recommendation to give, and inventing one from the least-bad row would read as advice.
    public var leader: UsageCandidate? {
        candidates.first(where: \.canLead)
    }

    /// The earliest moment any gated candidate frees up — what to say when `leader` is nil.
    ///
    /// Every `freesAt` is normalized to a future moment when the candidate is built, so this is
    /// simply the earliest of them — a reset that has already passed reaches nothing here.
    public var soonestReturn: Date? {
        candidates.compactMap(\.freesAt).min()
    }

    // MARK: - Thresholds

    /// Headroom at or above which the unspent budget is treated as use-it-or-lose-it.
    public static let spendThreshold = 0.20
    /// Headroom below which the account is burning faster than its week elapses.
    public static let paceThreshold = -0.10
    /// How far a challenger must beat the standing leader by before the answer changes.
    /// Without it the recommendation flips between two near-equal accounts on every poll,
    /// which reads as noise and costs a chat's context to follow.
    public static let stickyMargin = 0.05

    /// Rank `accounts` for `mode`.
    ///
    /// `previousLeader` is the account uuid this overview last recommended, and it exists only to
    /// damp the answer (see `stickyMargin`); the app layer holds it, so this stays a function of
    /// its arguments. Pass nil for an undamped ranking.
    public static func rank(
        accounts: [AccountUsage],
        mode: WorkMode,
        previousLeader: String? = nil,
        now: Date
    ) -> UsageOverview {
        let assessed = accounts.map { assess($0, mode: mode, now: now) }
        let ordered = assessed.sorted(by: precedes)
        return UsageOverview(
            candidates: applyStickiness(ordered, previousLeader: previousLeader),
            mode: mode
        )
    }
}
