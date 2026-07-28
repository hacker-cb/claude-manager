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
    /// Two things that carry over unchanged and one that must not: the identity and the snapshot
    /// are keyed by *this* binding, so they are its own history and stay; `bindingIDs` is the
    /// account-level fan-out from the pass that resolved it, and a sibling that shared the login may
    /// still be signed in — "shared with 2 profiles" over a login this binding no longer holds is
    /// the one field that has become false, so it collapses to this binding alone.
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
        for (id, failure) in result.bindingFailures {
            // A binding this pass *did* resolve was written above and wins: a re-login must not be
            // shadowed by the failure its own previous pass recorded.
            guard byBinding[id] == nil, var kept = previous[id], kept.snapshot != nil else { continue }
            kept.state = .noSource(failure)
            kept.bindingIDs = [id]
            byBinding[id] = kept
        }
        return byBinding
    }
}
