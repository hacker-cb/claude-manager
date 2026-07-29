import Foundation
import Testing
@testable import ClaudeManagerCore

/// `UsageService.mergeFailures` — the fold for the channel that speaks when a binding has no
/// `AccountUsage` at all.
///
/// Its own suite because its subject is the *other* half of a binding's published state. The two
/// halves are folded through one rule (`carried`) precisely so they cannot disagree, and the last
/// test here is the one that pins that.
struct UsageMergeFailuresTests {
    private func result(_ failures: [String: TokenProviderError]) -> UsageRefreshResult {
        UsageRefreshResult(accounts: [], bindingFailures: failures)
    }

    @Test
    func aFirstPassPublishesWhatItSaw() {
        let merged = UsageService.mergeFailures(previous: [:], result: result(["p": .signedOut]))
        #expect(merged == ["p": .signedOut])
    }

    @Test
    func anUnreadableConfigDoesNotUnSignOutABinding() {
        // The defect this fold exists for. A profile signed out before launch has no entry in the
        // account map — no snapshot to carry, no stored login to name — so the sidebar row, its cell
        // and its menu line speak only through this map. One poll landing while Claude Desktop
        // rewrites `config.json` used to replace `.signedOut` wholesale, and because only a sign-out
        // may speak without an account the row went silent on every surface at once.
        let merged = UsageService.mergeFailures(
            previous: ["p": .signedOut],
            result: result(["p": .configUnreadable])
        )
        #expect(merged == ["p": .signedOut])
        // And the row still has something to say — which is the property the silence broke, and the
        // one an assertion on the reason alone would not have caught.
        #expect(UsagePresentation.accountLine(usage: nil, failure: merged["p"]) == "Signed out")
        #expect(UsagePresentation.attention(usage: nil, failure: merged["p"])?.word == "Sign in")
    }

    @Test
    func aNeverSignedInBindingIsCarriedTheSameWay() {
        // `.noTokenCache` also `meansNotSignedIn`, so it is sticky in the same direction. It does not
        // speak without an account, so nothing on screen changes here — what matters is that a
        // rewrite cannot promote it into a *different* not-signed-in reason, which would flip the
        // pane's sentence between "isn't signed in" and "not set up yet".
        let merged = UsageService.mergeFailures(
            previous: ["p": .noTokenCache],
            result: result(["p": .configUnreadable])
        )
        #expect(merged == ["p": .noTokenCache])
    }

    @Test
    func aCurrentBlockerIsNeverHeldBehindAStaleSignOut() {
        // The other half of the narrow rule. A keychain refusal is as true after a sign-out as
        // before it, and it is the one failure with a remedy the user can act on — suppressed behind
        // a stale "signed out", a user who had signed back in would be told forever that they
        // hadn't. Same for every failure that names a real, current blocker of its own.
        for latest: TokenProviderError in [
            .keychainUnavailable(.interactionNotAllowed),
            .keychainUnavailable(.notFound),
            .decryptFailed(.decryptFailed),
            .malformedCache,
            .noUsableEntry,
            .noTokenCache
        ] {
            let merged = UsageService.mergeFailures(
                previous: ["p": .signedOut],
                result: result(["p": latest])
            )
            #expect(merged == ["p": latest], "carried a sign-out over \(latest)")
        }
    }

    @Test
    func anUnreadableConfigStandsAloneWithNothingToCarry() {
        // No prior knowledge at all — a launcher created and never opened. "Not set up yet" is the
        // truth here, and the stickiness must not invent a sign-out that never happened.
        let merged = UsageService.mergeFailures(previous: [:], result: result(["p": .configUnreadable]))
        #expect(merged == ["p": .configUnreadable])
    }

    @Test
    func aBindingThatResolvedThisPassLeavesTheMap() {
        // Built from this pass's failures, never from the previous map: a profile that signed back in
        // must stop being described by the reason it failed with last time. The account map speaks
        // for it now.
        let merged = UsageService.mergeFailures(previous: ["p": .signedOut], result: result([:]))
        #expect(merged.isEmpty)
    }

    @Test
    func bothHalvesOfOneBindingAgreeOnWhetherItSignedOut() {
        // The invariant the split cost us, asserted across the two folds rather than inside either.
        // `merge` carried the sign-out and `mergeFailures` did not, so one binding's row could be
        // told by the account map that it is signed out while the failure map called it unreadable —
        // and whichever surface read the other one printed the other answer.
        let previous = [
            "p": AccountUsage(
                identity: AccountIdentity(uuid: "A", email: "a@example.com"),
                snapshot: nil,
                state: .noSource(.signedOut),
                bindingIDs: ["p"]
            )
        ]
        let pass = result(["p": .configUnreadable])
        let accounts = UsageService.merge(previous: previous, result: pass)
        let failures = UsageService.mergeFailures(previous: ["p": .signedOut], result: pass)
        guard let state = accounts["p"]?.state, case let .noSource(reason) = state else {
            Issue.record("expected a carried no-source state, got \(accounts["p"]?.state as Any)")
            return
        }
        #expect(reason == failures["p"])
    }
}
