import Foundation

/// Folding one refresh pass into the per-binding state the UI renders.
///
/// A `static` rather than a step inside `refresh(bindings:interactive:)`, and deliberately so: the
/// service owns no memory between calls (see `UsageService`), and taking the previous map as a
/// parameter would make a pass's output a function of caller-held UI state. It would also move the
/// read of that map to *before* the app's generation check and its master-switch re-read, both of
/// which run after the pass returns — so a superseded pass would commit state the app had already
/// decided to discard. Pure, called by the app once both of its guards have passed, and testable
/// on its own, which the app-layer version it replaces never was.
public extension UsageService {
    /// The per-binding map to publish, given the pass's result and the map currently published.
    ///
    /// A binding whose token couldn't be read this pass is absent from `result.accounts`. Replacing
    /// wholesale would blank its figures, which is the opposite of the serve-stale promise — so its
    /// last snapshot is kept and restated as `.noSource(reason)`, carrying why it failed to every
    /// surface rather than only to the ones wired to `bindingFailures`.
    ///
    /// The identity and the snapshot carry over unchanged: the map is keyed by binding, so they are
    /// *this* binding's own history, not a sibling's. `bindingIDs` is the one field that can have
    /// become false — it is the account-level fan-out, and it stops being true the moment any
    /// binding leaves the account. So it is not patched but **recomputed**, once, from the whole
    /// pass: every entry on an account gets the same membership, and a binding with no login gets
    /// only itself. Repairing one side at a time is what left two panes on one login printing
    /// different counts, in both directions.
    static func merge(
        previous: [String: AccountUsage],
        result: UsageRefreshResult
    ) -> [String: AccountUsage] {
        var byBinding: [String: AccountUsage] = [:]
        for account in result.accounts {
            for bindingID in account.bindingIDs {
                byBinding[bindingID] = account
            }
        }
        // Bindings that hold no login at all any more. They belong to no account's fan-out, and
        // are the only entries whose own id is the whole of it.
        var detached: Set<String> = []
        for (id, failure) in result.bindingFailures {
            // A binding this pass *did* resolve was written above and wins: a re-login must not be
            // shadowed by the failure its own previous pass recorded.
            guard byBinding[id] == nil, var kept = previous[id] else { continue }
            // Something worth publishing: figures to serve, or a login worth naming in the past
            // tense. The second half is new, and it is what keeps a signed-out entry alive after the
            // rule below strips its figures — without it the entry would vanish on the very next
            // pass, taking the "was ps@…" clause with it.
            guard kept.snapshot != nil || kept.identity.accountLabel != nil else { continue }
            let reason = carriedReason(previous: kept.state, latest: failure)
            kept.state = .noSource(reason)
            if reason.meansNotSignedIn {
                detached.insert(id)
                // A profile that holds no login is not showing *stale* figures — it is showing
                // somebody else's, on a row whose own account is gone. The account owns the quota,
                // and this profile has stopped drawing on it, so the numbers are no longer about it
                // in any tense. The login it lost is still worth naming; the percentage is not.
                kept.snapshot = nil
            }
            byBinding[id] = kept
        }
        // Bindings whose own token said nothing this pass, attached to the account their config
        // names. Between the carry-forward and the fan-out on purpose: it needs the carried state
        // to have been decided, and the membership it creates has to be counted.
        attach(&byBinding, detached: &detached, previous: previous, result: result)
        // One definitive fan-out per account, computed after both halves because either can
        // contribute to it: the resolved account was built from resolved bindings alone, so a
        // sibling that merely couldn't be read is missing from it, while that sibling carried
        // forward a list that may still name a third profile which has since signed out. Patching
        // either side alone left two panes on one login printing different counts — and unioning
        // by account uuid re-inflated the very bindings that had just been detached from it.
        var members: [String: Set<String>] = [:]
        for (id, account) in byBinding where !detached.contains(id) {
            members[account.identity.uuid, default: []].insert(id)
        }
        for (id, account) in byBinding {
            var updated = account
            updated.bindingIDs = detached.contains(id) ? [id] : (members[account.identity.uuid] ?? [id])
                .sorted()
            byBinding[id] = updated
        }
        return byBinding
    }

    /// The per-binding failure map to publish, given this pass's failures and the map currently
    /// published. The twin of `merge`, for the channel that speaks when there is no `AccountUsage`
    /// at all.
    ///
    /// That channel is not a debug detail: a binding this app has never managed to resolve — signed
    /// out before launch, on a machine whose `account_profiles` has no row to name its login — has
    /// no entry in the map above, and its failure is the *only* thing the sidebar row, its cell and
    /// its menu line have to speak from. So it needs the same stickiness `merge` applies, and for
    /// the same reason: one poll that read `config.json` while Desktop was rewriting it replaced
    /// `.signedOut` with `.configUnreadable`, and since only a sign-out may speak without an
    /// account (`UsagePresentation.speaksWithoutAccount`), the row went **completely silent** —
    /// no account line, no cell, no menu suffix — until a later pass read the file again.
    ///
    /// Built from this pass's failures, never from the previous map: a binding that resolved a token
    /// this time is absent from both and must stay absent, rather than being kept alive by the
    /// reason it failed with last time.
    static func mergeFailures(
        previous: [String: TokenProviderError],
        result: UsageRefreshResult
    ) -> [String: TokenProviderError] {
        var merged = result.bindingFailures
        for (id, latest) in result.bindingFailures {
            merged[id] = carried(prior: previous[id], latest: latest)
        }
        return merged
    }

    /// Put every binding that could not speak for itself back into the account its `config.json`
    /// names — for **display**: a name, a membership, and (only where the profile is still signed
    /// in) the account's own figures.
    ///
    /// This is what stops a profile from leaving its login the moment we fail to read it. Three
    /// shapes arrive here and they are told apart by one thing, the failure that brought them:
    ///
    /// - **No failure at all.** The binding resolved a token, but it has expired and its
    ///   fingerprint has never been identified, so it stands alone as a phantom account keyed by
    ///   that fingerprint — printing an orange "Sign in" with no name beside a sibling on the same
    ///   login showing real figures. It gets the name and the membership. It keeps "Sign in":
    ///   unlike a keychain we could not read, an expired token is a fact about *this* profile's own
    ///   credential, and the row is the only place that can say so.
    /// - **A failure that is not a sign-out.** The profile is still signed in; we simply could not
    ///   read it. It gets the account's current figures, sourced from whichever sibling did resolve,
    ///   and keeps its own reason so the remedy still reaches every surface.
    /// - **A sign-out.** No figures, no membership — decided in the fold above and left alone here.
    ///   Only the name, so the row can say which login it lost.
    ///
    /// Nothing here is a donor for anything: the entries are read from `result.accounts`, never
    /// from the map being built, or attachments would chain — B borrowing from A, C from B's
    /// borrowed copy — and on a pass where nothing resolved every entry would repaint every other
    /// from stale figures.
    private static func attach(
        _ byBinding: inout [String: AccountUsage],
        detached: inout Set<String>,
        previous: [String: AccountUsage],
        result: UsageRefreshResult
    ) {
        guard !result.hintedAccounts.isEmpty else { return }
        var donors: [String: AccountUsage] = [:]
        for account in result.accounts {
            donors[account.identity.uuid] = account
        }

        for (id, identity) in result.hintedAccounts {
            // The failure is the discriminator, and it is exact: a binding is in `bindingFailures`
            // or in some account's fan-out, never both. So no guard against an entry donating to
            // itself is needed — the branch below reaches only bindings that resolved, and the ones
            // after it only bindings that did not, which by construction are in no donor.
            guard let failure = result.bindingFailures[id] else {
                attachExpired(&byBinding, id: id, identity: identity)
                continue
            }
            // Either this pass saw no login, or the last pass that could tell saw none. The second
            // half matters as much as the first: a keychain refusal says *nothing* about whether a
            // profile is signed in, so a binding that signed out and then hit one would otherwise
            // rejoin its account on the hint alone — and be handed a live sibling's quota bars, on
            // a row whose last positive knowledge was that it holds no login. `carriedReason`
            // deliberately lets the refusal replace the sign-out as the *reason shown*, because it
            // is current and actionable; that is about the copy, not about membership.
            guard !failure.meansNotSignedIn, !hadLostItsLogin(previous[id]) else {
                // The fold above published it if there was anything to keep; either way it may now
                // name the login it lost.
                var entry = byBinding[id]
                    ?? AccountUsage(
                        identity: identity,
                        snapshot: nil,
                        state: .noSource(failure),
                        bindingIDs: [id]
                    )
                entry.identity = identity
                entry.snapshot = nil
                byBinding[id] = entry
                detached.insert(id)
                continue
            }
            var entry = byBinding[id]
                ?? AccountUsage(
                    identity: identity,
                    snapshot: nil,
                    state: .noSource(failure),
                    bindingIDs: [id]
                )
            // Whether the figures already on this row are *this* account's, decided before the
            // name is overwritten — after that the entry can no longer say who they belonged to.
            let carriedAreThisAccounts = entry.identity.uuid == identity.uuid
            entry.identity = identity
            entry.snapshot = figures(
                for: entry,
                donor: donors[identity.uuid],
                keepCarried: carriedAreThisAccounts
            )
            byBinding[id] = entry
        }
    }

    /// Whether the last pass that could tell found this binding holding no login.
    ///
    /// Read from `previous`, not from the entry the fold has already restated: the carry-forward
    /// overwrites the state with *this* pass's reason, so by the time attachment runs the only
    /// record of what we last actually knew is the map we were given.
    private static func hadLostItsLogin(_ entry: AccountUsage?) -> Bool {
        guard let state = entry?.state, case let .noSource(prior) = state else { return false }
        return prior.meansNotSignedIn
    }

    /// The figures an attached row may show: a live sibling's, else its own carried ones, else
    /// none.
    ///
    /// The last case is the one that matters. A binding can arrive here carrying a snapshot from an
    /// account it is no longer attributed to — it resolved account A last pass, the user signed in
    /// as B, and this pass the keychain refused us before B was ever resolved for it. Keeping those
    /// figures would print A's quota bars under B's name, which is worse than printing none: the
    /// row would look entirely current and be about the wrong login.
    private static func figures(
        for entry: AccountUsage,
        donor: AccountUsage?,
        keepCarried: Bool
    ) -> UsageSnapshot? {
        // A sibling that resolved this pass is the same login and a fresher reading than anything
        // carried, so it wins outright.
        if let fresher = donor?.snapshot { return fresher }
        return keepCarried ? entry.snapshot : nil
    }

    /// The expired-token case: adopt the account's name, and nothing else.
    ///
    /// Guarded on the identity still being **provisional**, which is the whole safety of it. An
    /// account `/oauth/profile` has already named is authoritative about which login its token
    /// belongs to, and a hint disagreeing with it must lose — silently, since the hint is the
    /// fallible one. Only a fingerprint-keyed phantom, which by construction has no answer of its
    /// own, may take a name from the config.
    ///
    /// The figures go with it, and they have to. A phantom is usually figureless, but not always:
    /// a token whose `/profile` lookup keeps failing still fetches usage and stores it under the
    /// *fingerprint*, so once that token expires the phantom is served those samples. They belong
    /// to whatever login that token held, which the hint is only guessing at — and an expired-token
    /// row shows no figures either way, by the same rule that governs the surfaces above.
    private static func attachExpired(
        _ byBinding: inout [String: AccountUsage],
        id: String,
        identity: AccountIdentity
    ) {
        guard var phantom = byBinding[id], phantom.identity.isProvisional else { return }
        guard case .loginNeeded = phantom.state else { return }
        phantom.identity = identity
        phantom.snapshot = nil
        byBinding[id] = phantom
    }

    /// The reason to carry forward, read off the previous **state**.
    private static func carriedReason(
        previous: UsageState,
        latest: TokenProviderError
    ) -> TokenProviderError {
        guard case let .noSource(prior) = previous else { return latest }
        return carried(prior: prior, latest: latest)
    }

    /// The stickiness rule itself, in one place because it has two callers that must not diverge —
    /// the fold's carry-forward and `mergeFailures`. Living in one of them and being paraphrased in
    /// the other is exactly how the two halves of a binding's published state came to disagree.
    ///
    /// A binding that had already lost its login does not regain one because the next pass could
    /// not *read the file that would say so*. Without this the label flips from "Signed out" back
    /// to the e-mail of a login the profile no longer holds, on the first unrelated failure.
    ///
    /// Narrow to `.configUnreadable` on purpose, and this is the whole of the rule: every other
    /// failure names a real, current blocker of its own. A keychain that refuses us is exactly as
    /// true after a sign-out as before it, and it is actionable — held behind a stale "signed out"
    /// it would never be shown, so a user who had signed back in would be told forever that they
    /// hadn't, while Doctor named the keychain.
    ///
    /// `.noTokenCache` is deliberately **not** admitted alongside `.configUnreadable`, though it is
    /// the other way a rewrite in progress can be observed. A config that parses and simply has no
    /// cache key is also what a freshly recreated profile directory looks like, where "not signed
    /// in" is the truer of the two statements — and unlike a truncated file, this shape can persist,
    /// so a wrong carry here would be permanent rather than one pass long.
    private static func carried(
        prior: TokenProviderError?,
        latest: TokenProviderError
    ) -> TokenProviderError {
        guard let prior, prior.meansNotSignedIn, case .configUnreadable = latest else { return latest }
        return prior
    }
}
