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
    /// become false — it is the account-level fan-out from the pass that resolved it, and it stops
    /// being true only when this binding leaves the account. So it collapses **only** for a failure
    /// that means there is no login here at all. A keychain we merely couldn't read this tick
    /// leaves the sharing exactly as it was, and collapsing it there made "shared with 2 profiles"
    /// blink out of two panes on the first background poll after an "Allow"-not-"Always Allow".
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
        // Bindings that are still on their account and merely couldn't be read this pass, grouped
        // by it — see the fan-out repair below.
        var stillSharing: [String: Set<String>] = [:]
        for (id, failure) in result.bindingFailures {
            // A binding this pass *did* resolve was written above and wins: a re-login must not be
            // shadowed by the failure its own previous pass recorded.
            guard byBinding[id] == nil, var kept = previous[id], kept.snapshot != nil else { continue }
            let reason = carriedReason(previous: kept.state, latest: failure)
            kept.state = .noSource(reason)
            if reason.meansNotSignedIn {
                kept.bindingIDs = [id]
            } else {
                stillSharing[kept.identity.uuid, default: []].insert(id)
            }
            byBinding[id] = kept
        }
        // The account this pass *did* resolve was built from resolved bindings alone, so a sibling
        // that failed transiently is missing from its fan-out — and the failed sibling kept the old
        // one. Both panes then describe one login two ways: "shared with 2 profiles" on the side
        // that couldn't be read, and nothing on the side that could. Union them back.
        for (uuid, ids) in stillSharing {
            for (bindingID, account) in byBinding where account.identity.uuid == uuid {
                var updated = account
                updated.bindingIDs = Set(account.bindingIDs).union(ids).sorted()
                byBinding[bindingID] = updated
            }
        }
        return byBinding
    }

    /// The reason to carry forward.
    ///
    /// A binding that had already lost its login does not regain one because the next pass failed
    /// to *read* its config or its keychain: only a successful resolve says the login is back, and
    /// that path never reaches here. Without this the label flips from "Signed out" back to the
    /// e-mail of a login the profile no longer holds, on the first unrelated failure after it.
    private static func carriedReason(
        previous: UsageState,
        latest: TokenProviderError
    ) -> TokenProviderError {
        guard case let .noSource(prior) = previous, prior.meansNotSignedIn, !latest.meansNotSignedIn
        else { return latest }
        return prior
    }
}
