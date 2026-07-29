import Foundation

/// Turning a binding's `config.json` hint — a bare account uuid — into something nameable.
///
/// Its own file because it is the one part of the pass that reaches the store for a reason other
/// than usage: no sample, no throttle window, no ledger. It runs **after** every call and every
/// write, which is what keeps the display/filing boundary a property of the code's shape rather
/// than of everybody remembering it (see `CoreConstants.desktopAccountHintKey`).
extension UsageService {
    /// Resolve each hinted uuid to an identity, or drop it.
    ///
    /// Two sources, in order: an account **this pass** produced, which is as authoritative as
    /// naming gets; then `account_profiles`, the local record of every `/oauth/profile` answer this
    /// machine has ever stored. The second is what makes the common single-launcher-per-login shape
    /// work at all — there is no sibling to borrow a name from, and a signed-out row would
    /// otherwise have nothing to say but "Signed out".
    ///
    /// A hint that resolves to neither is **dropped entirely**, which is the property that bounds
    /// how wrong this can go: a hint may only ever point at an account something else already
    /// knows about, so it can misattribute a row to a real login and can never invent one.
    func hintedAccounts(
        _ hints: [String: String],
        among accounts: [AccountUsage]
    ) async -> [String: AccountIdentity] {
        // A healthy fleet hints nothing, and pays for nothing.
        guard !hints.isEmpty else { return [:] }
        var known: [String: AccountIdentity] = [:]
        for account in accounts {
            known[account.identity.uuid] = account.identity
        }

        var resolved: [String: AccountIdentity] = [:]
        for (bindingID, uuid) in hints {
            if let identity = known[uuid] {
                resolved[bindingID] = identity
                continue
            }
            guard let stored = await history.profile(accountUUID: uuid) else { continue }
            // Remembered, so a fleet of launchers all hinting one login costs one lookup rather
            // than one per binding.
            known[uuid] = stored
            resolved[bindingID] = stored
        }
        return resolved
    }
}
