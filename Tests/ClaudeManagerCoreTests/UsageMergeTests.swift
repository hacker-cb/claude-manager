import Foundation
import Testing
@testable import ClaudeManagerCore

/// `UsageService.merge` — the fold from one refresh pass into the per-binding map every surface
/// renders. It lived inline in the app layer, where nothing could reach it; these are the first
/// assertions the rule has ever had.
struct UsageMergeTests {
    private let capturedAt = Date(timeIntervalSince1970: 1_785_000_000)

    private func snapshot(_ utilization: Double) -> UsageSnapshot {
        UsageSnapshot(
            limits: [UsageLimit(rawKind: UsageLimit.kindSession, utilization: utilization, isActive: true)],
            capturedAt: capturedAt
        )
    }

    private func account(
        uuid: String,
        email: String? = nil,
        snapshot: UsageSnapshot?,
        state: UsageState = .fresh,
        bindingIDs: [String]
    ) -> AccountUsage {
        AccountUsage(
            identity: AccountIdentity(uuid: uuid, email: email),
            snapshot: snapshot,
            state: state,
            bindingIDs: bindingIDs
        )
    }

    // MARK: - The resolved half

    @Test
    func aResolvedAccountFansOutToEveryBindingItCovers() {
        let shared = account(uuid: "A", snapshot: snapshot(0.2), bindingIDs: ["one", "two"])
        let merged = UsageService.merge(
            previous: [:],
            result: UsageRefreshResult(accounts: [shared], bindingFailures: [:])
        )
        #expect(merged.keys.sorted() == ["one", "two"])
        #expect(merged["one"] == shared)
        #expect(merged["two"] == shared)
    }

    @Test
    func anEmptyResultLeavesTheMapEmpty() {
        // A pass cancelled by the master switch returns nothing at all. Carrying anything forward
        // here would repopulate state the app has decided to clear.
        let merged = UsageService.merge(
            previous: ["p": account(uuid: "A", snapshot: snapshot(0.2), bindingIDs: ["p"])],
            result: UsageRefreshResult(accounts: [], bindingFailures: [:])
        )
        #expect(merged.isEmpty)
    }

    @Test
    func aResolvedBindingOverwritesItsPreviousNoSource() {
        // Signing back in must win over the failure the last pass recorded for that same binding.
        let previous = [
            "p": account(uuid: "A", snapshot: snapshot(0.2), state: .noSource(.signedOut), bindingIDs: ["p"])
        ]
        let fresh = account(uuid: "A", snapshot: snapshot(0.5), bindingIDs: ["p"])
        let merged = UsageService.merge(
            previous: previous,
            result: UsageRefreshResult(accounts: [fresh], bindingFailures: ["p": .signedOut])
        )
        #expect(merged["p"] == fresh)
    }

    // MARK: - The carried-forward half

    @Test
    func aFailedBindingKeepsItsOwnSnapshot() {
        // The serve-stale promise: a keychain that locked mid-session must not blank the figures.
        let previous = ["p": account(
            uuid: "A",
            email: "a@example.com",
            snapshot: snapshot(0.4),
            bindingIDs: ["p"]
        )]
        let merged = UsageService.merge(
            previous: previous,
            result: UsageRefreshResult(
                accounts: [],
                bindingFailures: ["p": .keychainUnavailable(.interactionNotAllowed)]
            )
        )
        #expect(merged["p"]?.snapshot == snapshot(0.4))
        #expect(merged["p"]?.identity.email == "a@example.com")
    }

    @Test
    func aTransientFailureKeepsTheBindingIDsItStillShares() {
        // A keychain that couldn't be read leaves the login — and therefore the sharing — exactly
        // as it was. Collapsing here made "shared with 2 profiles" blink out of both panes on the
        // first background poll after an "Allow" that wasn't an "Always Allow".
        let shared = account(uuid: "A", snapshot: snapshot(0.3), bindingIDs: ["one", "two"])
        let merged = UsageService.merge(
            previous: ["one": shared, "two": shared],
            result: UsageRefreshResult(
                accounts: [],
                bindingFailures: [
                    "one": .keychainUnavailable(.interactionNotAllowed),
                    "two": .keychainUnavailable(.interactionNotAllowed)
                ]
            )
        )
        #expect(merged["one"]?.bindingIDs == ["one", "two"])
        #expect(merged["two"]?.bindingIDs == ["one", "two"])
    }

    @Test
    func theCarriedForwardStateNamesTheFailureThatCausedIt() {
        // The whole point of the payload: the reason has to survive the fold, or the sidebar and
        // the menu bar — which read `UsageState` and nothing else — cannot name a remedy.
        let previous = ["p": account(uuid: "A", snapshot: snapshot(0.4), bindingIDs: ["p"])]
        let merged = UsageService.merge(
            previous: previous,
            result: UsageRefreshResult(accounts: [], bindingFailures: ["p": .signedOut])
        )
        #expect(merged["p"]?.state == .noSource(.signedOut))
    }

    @Test
    func aFailedBindingWithNoPreviousSnapshotProducesNoEntry() {
        // Nothing to serve stale. The binding's failure is published separately and is what the
        // detail pane's empty state reads.
        let previous = ["p": account(uuid: "A", snapshot: nil, bindingIDs: ["p"])]
        let merged = UsageService.merge(
            previous: previous,
            result: UsageRefreshResult(accounts: [], bindingFailures: ["p": .signedOut])
        )
        #expect(merged["p"] == nil)
    }

    @Test
    func aFailedBindingCollapsesTheBindingIDsItNoLongerShares() {
        // Two launchers on one login: one signs out, the other stays. The carried-forward entry
        // must stop claiming "shared with 2 profiles" over a login it no longer holds.
        let shared = account(uuid: "A", snapshot: snapshot(0.3), bindingIDs: ["out", "live"])
        let stillLive = account(uuid: "A", snapshot: snapshot(0.6), bindingIDs: ["live"])
        let merged = UsageService.merge(
            previous: ["out": shared, "live": shared],
            result: UsageRefreshResult(accounts: [stillLive], bindingFailures: ["out": .signedOut])
        )
        #expect(merged["out"]?.bindingIDs == ["out"])
        #expect(merged["live"]?.bindingIDs == ["live"])
    }

    @Test
    func aTransientlyFailedSiblingStaysInTheResolvedAccountsFanOut() {
        // The resolved account is built from resolved bindings alone, so a sibling that merely
        // couldn't be read is missing from its fan-out while the failed side keeps the old one.
        // Both panes then describe one login two ways: "shared with 2 profiles" on the side that
        // couldn't be read, and nothing on the side that could.
        let shared = account(uuid: "A", snapshot: snapshot(0.3), bindingIDs: ["live", "unread"])
        let resolved = account(uuid: "A", snapshot: snapshot(0.6), bindingIDs: ["live"])
        let merged = UsageService.merge(
            previous: ["live": shared, "unread": shared],
            result: UsageRefreshResult(
                accounts: [resolved],
                bindingFailures: ["unread": .configUnreadable]
            )
        )
        #expect(merged["live"]?.bindingIDs == ["live", "unread"])
        #expect(merged["unread"]?.bindingIDs == ["live", "unread"])
    }

    @Test
    func aBindingThatLostItsLoginDoesNotRegainOneOnAnUnrelatedFailure() {
        // Only a successful resolve says the login is back. Without this the label flipped from
        // "Signed out" to the e-mail of a login the profile no longer holds on the first read
        // failure after the sign-out.
        let signedOut = account(
            uuid: "A", snapshot: snapshot(0.4), state: .noSource(.signedOut), bindingIDs: ["p"]
        )
        let merged = UsageService.merge(
            previous: ["p": signedOut],
            result: UsageRefreshResult(accounts: [], bindingFailures: ["p": .configUnreadable])
        )
        #expect(merged["p"]?.state == .noSource(.signedOut))
        #expect(merged["p"]?.bindingIDs == ["p"])
    }

    @Test
    func aStrongerFailureStillReplacesTheCarriedOne() {
        // The stickiness is one-way: a binding that could not be read and then turns out to be
        // signed out must take the newer, more specific verdict.
        let unread = account(
            uuid: "A",
            snapshot: snapshot(0.4),
            state: .noSource(.keychainUnavailable(.interactionNotAllowed)),
            bindingIDs: ["p"]
        )
        let merged = UsageService.merge(
            previous: ["p": unread],
            result: UsageRefreshResult(accounts: [], bindingFailures: ["p": .signedOut])
        )
        #expect(merged["p"]?.state == .noSource(.signedOut))
    }

    @Test
    func aResolvedSiblingKeepsItsFreshFigures() {
        // The other half of the shared-login case: the profile that is still signed in must be
        // untouched by its former partner's failure.
        let shared = account(uuid: "A", snapshot: snapshot(0.3), bindingIDs: ["out", "live"])
        let stillLive = account(uuid: "A", snapshot: snapshot(0.6), bindingIDs: ["live"])
        let merged = UsageService.merge(
            previous: ["out": shared, "live": shared],
            result: UsageRefreshResult(accounts: [stillLive], bindingFailures: ["out": .signedOut])
        )
        #expect(merged["live"]?.state == .fresh)
        #expect(merged["live"]?.snapshot == snapshot(0.6))
    }
}
