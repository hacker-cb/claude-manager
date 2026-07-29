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
            guard byBinding[id] == nil, var kept = previous[id], kept.snapshot != nil else { continue }
            let reason = carriedReason(previous: kept.state, latest: failure)
            kept.state = .noSource(reason)
            if reason.meansNotSignedIn { detached.insert(id) }
            byBinding[id] = kept
        }
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

    /// The reason to carry forward.
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
    private static func carriedReason(
        previous: UsageState,
        latest: TokenProviderError
    ) -> TokenProviderError {
        guard case let .noSource(prior) = previous, prior.meansNotSignedIn,
              case .configUnreadable = latest
        else { return latest }
        return prior
    }
}
