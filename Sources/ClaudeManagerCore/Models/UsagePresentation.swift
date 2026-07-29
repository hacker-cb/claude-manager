import Foundation

/// What the UI says about one binding, decided once — in core, where `swift test` can reach it.
///
/// Every rule here used to live in the SwiftUI layer, which this package has no test target for, so
/// each of them was verifiable only by reading it. They drifted exactly as you would expect: the
/// sidebar tinted a state orange while the pane it linked to called the same state unremarkable,
/// the "drop an elapsed countdown" rule reached one of its two call sites, and the same explanation
/// was printed twice in one pane. The views now paint what this decides and choose nothing
/// themselves.
///
/// The *copy* still differs per surface, deliberately — a 66pt cell, a hover phrase and a full
/// sentence are different registers, and collapsing them was never the goal. What must not differ,
/// and now cannot, is the classification underneath: which failure means what, and whether it is a
/// malfunction or a normal condition.
public enum UsagePresentation {
    // MARK: - Classification

    /// Whether a state is a **malfunction** rather than a normal or intended condition — the one
    /// flag every surface tints from.
    ///
    /// Signing out, never having signed in, and a launcher not yet opened are all things the user
    /// did or simply hasn't done; painting them as alerts puts a standing warning on a row no
    /// action clears, and spending the warning colour on a non-warning is how a warning colour
    /// stops meaning anything. A keychain that refused us, a blob that won't decrypt and a cache
    /// in an unexpected shape are genuine faults, and keep it.
    ///
    /// Exhaustive on purpose: a `default:` arm here would silently classify a future failure, which
    /// is precisely how the tables this replaces came to disagree.
    public static func isWarning(_ failure: TokenProviderError) -> Bool {
        switch failure {
        case .signedOut, .noTokenCache, .configUnreadable: false
        case .keychainUnavailable, .decryptFailed, .malformedCache, .noUsableEntry: true
        }
    }

    /// Whether a surface with **no resolved account** may speak for a binding at all.
    ///
    /// Narrow on purpose. A binding with no account has produced no usage in this process, and most
    /// of the ways that happens are permanent, intended states: a launcher created and not yet
    /// opened has no `config.json` (`.configUnreadable`), and the default binding of someone who
    /// only uses launchers is permanently `.noTokenCache`. Speaking for those puts an unclearable
    /// instruction on a row whose condition is normal.
    ///
    /// `.signedOut` is the exception, and provably so: an encrypted *empty* cache exists only
    /// because Desktop wrote one on logout, so that binding was signed in and no longer is.
    public static func speaksWithoutAccount(_ failure: TokenProviderError?) -> Bool {
        failure == .signedOut
    }

    // MARK: - The account line

    /// What a surface prints where the binding's login goes: the login, or the state that replaced
    /// it, or nothing. Shared by the sidebar row and both detail-pane headers, which ask the same
    /// question of the same binding and must not answer differently.
    ///
    /// A binding that has lost its login says so rather than printing an e-mail that is no longer
    /// true of it — but keeps that e-mail as a past-tense clause, because it is still the most
    /// useful thing on the line for telling two profiles apart.
    public static func accountLine(usage: AccountUsage?, failure: TokenProviderError?) -> String? {
        guard let usage else {
            guard speaksWithoutAccount(failure) else { return nil }
            return capitalized(phrase(for: .signedOut, hasFigures: false))
        }
        guard case let .noSource(reason) = usage.state, reason.meansNotSignedIn else {
            return usage.identity.accountLabel
        }
        let state = capitalized(phrase(for: reason, hasFigures: usage.snapshot != nil))
        guard let label = usage.identity.accountLabel else { return state }
        return "\(state) · was \(label)"
    }

    // MARK: - Naming an account

    /// What to call an account where a *login*, not a profile row, is the subject — a notification
    /// title, the Doctor inspector's picker.
    ///
    /// A shared login is named by the **login**. Naming it after a member profile is arbitrary the
    /// moment there is more than one: the previous rule walked a sorted binding list and took the
    /// first match, so a notification about a quota two profiles share was titled after whichever
    /// launcher path sorted lowest — a name the reader may not associate with that account at all,
    /// and one that changes if they rename a launcher.
    ///
    /// A login with a single profile keeps the profile's name, which is the more useful of the two
    /// there: it is what the sidebar row says, and there is no ambiguity to resolve.
    ///
    /// `profileNames` maps a binding id to what the UI calls it — supplied by the app, which is the
    /// only layer that knows launcher display names.
    public static func accountName(
        _ account: AccountUsage,
        profileNames: [String: String]
    ) -> String {
        let login = account.identity.accountLabel
        if account.bindingIDs.count > 1, let login { return login }
        return profileName(account, profileNames) ?? login ?? "Claude account"
    }

    /// The member profile to name a login after, when the login itself has no name yet.
    ///
    /// The default profile wins where it is a member, and that precedence is load-bearing rather
    /// than decorative: a cloned user-data dir puts the default binding and a launcher on one
    /// account, `bindingIDs` is sorted, and a launcher's id is an `.app` path — which sorts *before*
    /// `__default__`. Take the first and the default profile is named after whichever launcher
    /// happens to share its directory, which is precisely the arbitrary sorted-first pick this
    /// function exists to stop.
    private static func profileName(
        _ account: AccountUsage,
        _ profileNames: [String: String]
    ) -> String? {
        let hasDefault = account.bindingIDs.contains(TokenBinding.defaultID)
        if hasDefault, let name = profileNames[TokenBinding.defaultID] { return name }
        return account.bindingIDs.compactMap { profileNames[$0] }.first
    }

    // MARK: - The compact cell

    /// The word a compact cell prints instead of a percentage when the binding needs the user, and
    /// whether it reads as a warning. Nil when the cell should print figures, or nothing.
    public static func attention(
        usage: AccountUsage?,
        failure: TokenProviderError?
    ) -> (word: String, isWarning: Bool)? {
        guard let usage else {
            guard speaksWithoutAccount(failure) else { return nil }
            return (word(for: .signedOut), isWarning(.signedOut))
        }
        switch usage.state {
        // The API rejected the token — a surprise the user did not cause, so it keeps the colour.
        case .loginNeeded: return ("Sign in", true)
        case let .noSource(reason): return (word(for: reason), isWarning(reason))
        case .fresh, .stale, .rateLimited, .offline: return nil
        }
    }

    /// The **constant** phrase behind an attention word, for a hover or a menu row. Constant is
    /// load-bearing: the sidebar hands an attention state to a non-ticking tooltip precisely
    /// because this cannot change while it is on screen.
    public static func attentionNote(usage: AccountUsage?, failure: TokenProviderError?) -> String? {
        guard let usage else {
            guard speaksWithoutAccount(failure) else { return nil }
            return phrase(for: .signedOut, hasFigures: false)
        }
        guard attention(usage: usage, failure: failure) != nil else { return nil }
        return stateNote(usage)
    }

    // MARK: - The detail pane

    /// The pane's short header note and whether it warns — nil when the header should stay quiet.
    ///
    /// Quiet whenever the pane has **no figures**: with nothing to render, the body already owns
    /// the full sentence for the state, and printing a two-word version of it directly above reads
    /// as a stutter rather than emphasis. That was true of a no-account pane from the start and is
    /// now true of every state that can arrive without a snapshot — a 429 on a first-ever fetch, an
    /// offline start, and a signed-out profile, which no longer carries figures at all.
    ///
    /// Every state that *does* render bars is dated. The figures have stopped moving, the countdown
    /// beside them goes once their window elapses, and a state word alone says nothing about *when*
    /// — so without an age a day-old 87% reads as the current quota.
    public static func headerNote(
        usage: AccountUsage?,
        now: Date
    ) -> (text: String, isWarning: Bool)? {
        // Bound once. The guard already settled that there are figures, and re-asking three more
        // times below invited exactly the reading it is meant to prevent — that some arm here could
        // still be answering for a pane with nothing in it.
        guard let usage, let snapshot = usage.snapshot else { return nil }
        let dated = { (text: String, warn: Bool) -> (text: String, isWarning: Bool) in
            guard let capturedAt = snapshot.capturedAt else { return (text, warn) }
            return ("\(text) · as of \(UsageFormat.age(capturedAt, now: now))", warn)
        }
        switch usage.state {
        case .fresh:
            return snapshot.capturedAt.map { ("updated \(UsageFormat.age($0, now: now))", false) }
        case let .stale(since): return ("stale · \(UsageFormat.age(since, now: now))", false)
        case .rateLimited: return dated("rate limited", true)
        case .offline: return dated("offline", false)
        case .loginNeeded: return dated("sign in to refresh", true)
        case let .noSource(reason):
            return dated(phrase(for: reason, hasFigures: true), isWarning(reason))
        }
    }

    /// The full sentence for a pane with no figures to show — the state named, a remedy that can
    /// actually be followed, and whether it warns. Nil when there is nothing to explain.
    ///
    /// It carries the tint because it is the only thing left on such a pane to carry it. The header
    /// used to, but a pane with no figures has nothing for the header to date, so it now stays
    /// quiet — and that silence would otherwise have taken the pane's one warning signal with it,
    /// leaving a keychain error and a normal sign-out drawn identically.
    public static func sentence(
        usage: AccountUsage?,
        failure: TokenProviderError?
    ) -> (text: String, isWarning: Bool)? {
        guard let usage else {
            return failure.map { (sentence(for: $0), isWarning($0)) }
        }
        switch usage.state {
        case .loginNeeded: return ("Sign in to this account in Claude to see usage.", true)
        case let .noSource(reason): return (sentence(for: reason), isWarning(reason))
        case .offline: return ("Offline — no usage yet.", false)
        // Without this the header says "rate limited" while the body falls through to "Not
        // checked yet — use Refresh", which contradicts it and points at a Refresh that is
        // itself inside the backoff.
        case .rateLimited: return ("Rate limited — usage will refresh once the window clears.", true)
        case .fresh, .stale: return nil
        }
    }

    /// Whether a limit row may print a reset phrase.
    ///
    /// Only while the window is still ahead. That timestamp is the server's own and stays true
    /// through a stale or rate-limited pass, where on a near-full weekly row it is the most useful
    /// figure there is — but once it has passed, the phrase becomes "resetting…" forever, and
    /// `.fresh` is no protection: a snapshot re-served inside the poll floor, or the only one a
    /// "Manually only" user ever fetched, is `.fresh` and hours old.
    public static func showsReset(_ resetsAt: Date?, now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt > now
    }

    // MARK: - Per-failure copy

    /// One word for a compact cell, from the failure's own remedy.
    private static func word(for failure: TokenProviderError) -> String {
        switch failure.remedy {
        case .signIn: "Sign in"
        case .authorizeKeychain: "Authorize"
        case .none: "Unavailable"
        }
    }

    /// The lowercase phrase for a header note or a hover.
    ///
    /// `hasFigures` is not decoration: "not set up yet" is true of a launcher nobody has opened and
    /// plainly false above that binding's own usage bars, which is what a transient unreadable
    /// `config.json` on a months-old profile produces.
    private static func phrase(for failure: TokenProviderError, hasFigures: Bool) -> String {
        switch failure {
        // Signed-out and never-signed-in share a remedy but not a tense, and the tense is the
        // useful part: one says the login went away, the other that it was never made.
        case .signedOut: "signed out"
        case .noTokenCache: "not signed in"
        case .configUnreadable: hasFigures ? "config unreadable" : "not set up yet"
        case let .keychainUnavailable(error):
            switch error {
            case .interactionNotAllowed: "authorize keychain access"
            case .notFound: "keychain item missing"
            case .unexpected: "keychain error"
            }
        case .decryptFailed, .malformedCache, .noUsableEntry: "source unavailable"
        }
    }

    /// The full sentence for a pane with no figures.
    private static func sentence(for failure: TokenProviderError) -> String {
        switch failure {
        case .signedOut: "Signed out — open Claude on this profile and sign in to see usage."
        case .noTokenCache: "This account isn't signed in on this profile."
        case .configUnreadable: "Not set up yet — open this profile once, then Refresh."
        case let .keychainUnavailable(error):
            switch error {
            // The reader is *in* Claude Manager, looking at this pane; telling them to open it is
            // the one instruction that cannot be followed.
            case .interactionNotAllowed: "Refresh to authorize keychain access."
            // A missing item can't be authorized — Refresh won't prompt — so name the real cause.
            case .notFound:
                "Claude's keychain item wasn't found — open Claude and sign in on this profile, then Refresh."
            case .unexpected: "Usage source unavailable — a keychain error blocked the token."
            }
        case .decryptFailed, .malformedCache, .noUsableEntry: "Usage unavailable for this account."
        }
    }

    /// The phrase for a state, for a tooltip, a menu row, or the qualifier a screen reader needs on
    /// a figure that has stopped moving.
    ///
    /// Constant **in time**, which is the invariant the sidebar's non-ticking tooltip relies on —
    /// and `hasFigures` does not threaten it: whether a snapshot exists is a property of the
    /// reading, not of the clock. Taking the whole `AccountUsage` rather than its state alone is
    /// what lets this arm agree with the pane's header instead of calling an already-running
    /// profile "not set up yet".
    public static func stateNote(_ usage: AccountUsage, now: Date = Date()) -> String {
        switch usage.state {
        case .fresh: "up to date"
        case let .stale(since): "as of \(UsageFormat.age(since, now: now))"
        case .loginNeeded: "login needed"
        case .rateLimited: "rate limited"
        case let .noSource(reason): phrase(for: reason, hasFigures: usage.snapshot != nil)
        case .offline: "offline"
        }
    }

    private static func capitalized(_ phrase: String) -> String {
        phrase.prefix(1).uppercased() + phrase.dropFirst()
    }
}
