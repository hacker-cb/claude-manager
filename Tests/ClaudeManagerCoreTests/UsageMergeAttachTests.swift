import Foundation
import Testing
@testable import ClaudeManagerCore

/// Attaching a binding that could not speak for itself to the account its `config.json` names.
///
/// One test per row of the rule, plus the negatives that bound it: a hint may never overrule a
/// token, never widen a fan-out with a profile that has no login, and never chain one attachment
/// off another.
extension UsageMergeTests {
    private var acct: AccountIdentity {
        AccountIdentity(uuid: "A", email: "a@example.com")
    }

    /// The phantom an expired, never-identified token produces: keyed by its own fingerprint,
    /// `.loginNeeded`, no figures, alone in its fan-out.
    private func phantom(_ id: String) -> AccountUsage {
        AccountUsage(
            identity: AccountIdentity(uuid: "fingerprint-\(id)", isProvisional: true),
            snapshot: nil,
            state: .loginNeeded,
            bindingIDs: [id]
        )
    }

    // MARK: - An expired token keeps "Sign in", and stops being anonymous

    @Test
    func anExpiredTokenLearnsItsAccountWithoutLearningItsFigures() {
        // The defect: two profiles on one login, one showing `7d 54%` and the other an orange
        // "Sign in" with no name at all — because its token had expired and its fingerprint had
        // never been through `/profile`, so it stood alone as an account of its own.
        //
        // It joins the login and takes its name. It does **not** take the figures: unlike a
        // keychain we could not read, an expired token is a fact about this profile's own
        // credential, and this row is the only place that can say so.
        let live = account(uuid: "A", email: "a@example.com", snapshot: snapshot(0.6), bindingIDs: ["live"])
        let byBinding = UsageService.merge(
            previous: [:],
            result: UsageRefreshResult(
                accounts: [live, phantom("stale")],
                bindingFailures: [:],
                hintedAccounts: ["stale": acct]
            )
        )
        #expect(byBinding["stale"]?.identity.email == "a@example.com")
        #expect(byBinding["stale"]?.state == .loginNeeded)
        #expect(byBinding["stale"]?.snapshot == nil)
        // Both sides of one login now agree they are two profiles on it.
        byBinding["stale"].map { #expect($0.bindingIDs == ["live", "stale"]) }
        #expect(byBinding["live"]?.bindingIDs == ["live", "stale"])
    }

    @Test
    func aHintNeverOverrulesAnAccountProfileAlreadyNamed() {
        // The one way this could file a row under the wrong login. An account `/oauth/profile` has
        // answered for is authoritative about which login its token belongs to; a config hint that
        // disagrees is the fallible one and loses silently.
        let named = AccountUsage(
            identity: AccountIdentity(uuid: "B", email: "b@example.com"),
            snapshot: nil,
            state: .loginNeeded,
            bindingIDs: ["p"]
        )
        let merged = UsageService.merge(
            previous: [:],
            result: UsageRefreshResult(
                accounts: [named],
                bindingFailures: [:],
                hintedAccounts: ["p": acct]
            )
        )
        #expect(merged["p"]?.identity.uuid == "B")
        #expect(merged["p"]?.identity.email == "b@example.com")
    }

    // MARK: - Signed in, merely unreadable: the account's figures

    @Test
    func anUnreadableBindingShowsTheAccountsCurrentFigures() {
        // A locked keychain leaves the login in place. Its row used to serve its own older
        // carried-forward numbers while the sibling that *could* be read showed newer ones for the
        // same login — two panes disagreeing about one account's quota.
        let live = account(uuid: "A", email: "a@example.com", snapshot: snapshot(0.6), bindingIDs: ["live"])
        let stale = account(
            uuid: "A",
            email: "a@example.com",
            snapshot: snapshot(0.3),
            bindingIDs: ["locked"]
        )
        let refused = TokenProviderError.keychainUnavailable(.interactionNotAllowed)
        let merged = UsageService.merge(
            previous: ["locked": stale],
            result: UsageRefreshResult(
                accounts: [live],
                bindingFailures: ["locked": refused],
                hintedAccounts: ["locked": acct]
            )
        )
        #expect(merged["locked"]?.snapshot == snapshot(0.6))
        // …and still names its own blocker, so the remedy reaches every surface.
        #expect(merged["locked"]?.state == .noSource(refused))
        #expect(merged["locked"]?.bindingIDs == ["live", "locked"])
    }

    @Test
    func anUnreadableBindingIsNamedEvenOnAColdStart() {
        // Nothing carried forward — the app has just launched — so before the hint this row had no
        // account, no name and no cell at all. `.malformedCache` says nothing about whether the
        // profile is signed in, and the answer is available with no keychain and no network.
        let merged = UsageService.merge(
            previous: [:],
            result: UsageRefreshResult(
                accounts: [],
                bindingFailures: ["p": .malformedCache],
                hintedAccounts: ["p": acct]
            )
        )
        #expect(merged["p"]?.identity.email == "a@example.com")
        #expect(merged["p"]?.state == .noSource(.malformedCache))
        #expect(merged["p"]?.snapshot == nil)
    }

    @Test
    func anUnreadableBindingWithNoLiveSiblingKeepsItsOwnFigures() {
        // Nobody resolved that account this pass, so there is nothing fresher to show. The carried
        // snapshot is the best available and stays.
        let carried = account(uuid: "A", email: "a@example.com", snapshot: snapshot(0.3), bindingIDs: ["p"])
        let merged = UsageService.merge(
            previous: ["p": carried],
            result: UsageRefreshResult(
                accounts: [],
                bindingFailures: ["p": .malformedCache],
                hintedAccounts: ["p": acct]
            )
        )
        #expect(merged["p"]?.snapshot == snapshot(0.3))
    }

    // MARK: - Signed out: the name, and nothing else

    @Test
    func aSignedOutBindingTakesTheNameButNeitherFiguresNorMembership() {
        // The state the whole investigation started from. It may say which login it lost — that is
        // the most useful thing on the row — but it is not on that login any more, so it shows no
        // figures and must not appear in its sibling's "shared with N profiles".
        let live = account(uuid: "A", email: "a@example.com", snapshot: snapshot(0.6), bindingIDs: ["live"])
        let merged = UsageService.merge(
            previous: [:],
            result: UsageRefreshResult(
                accounts: [live],
                bindingFailures: ["out": .signedOut],
                hintedAccounts: ["out": acct]
            )
        )
        #expect(merged["out"]?.identity.email == "a@example.com")
        #expect(merged["out"]?.state == .noSource(.signedOut))
        #expect(merged["out"]?.snapshot == nil)
        #expect(merged["out"]?.bindingIDs == ["out"])
        #expect(merged["live"]?.bindingIDs == ["live"])
    }

    @Test
    func aSignedOutBindingIsNamedOnAColdStartWithNothingCarried() {
        // Before this, "Signed out · was ps@…" could only appear if the sign-out happened while the
        // app was watching — `previous` is empty at every launch, so the clause was effectively
        // dead code. The name now comes from the hint plus the local account record instead.
        let merged = UsageService.merge(
            previous: [:],
            result: UsageRefreshResult(
                accounts: [],
                bindingFailures: ["out": .signedOut],
                hintedAccounts: ["out": acct]
            )
        )
        #expect(UsagePresentation.accountLine(usage: merged["out"], failure: .signedOut)
            == "Signed out · was a@example.com")
    }

    @Test
    func aHintThatSwitchesAccountsDoesNotCarryTheOldOnesFigures() {
        // The row resolved account A last pass, the user signed in as B, and this pass the keychain
        // refused us before B had ever been resolved for it. Renaming the entry while keeping A's
        // snapshot would print A's quota bars under B's name — worse than printing none, because
        // the row then looks entirely current and is about the wrong login.
        let onA = account(uuid: "A", email: "a@example.com", snapshot: snapshot(0.3), bindingIDs: ["p"])
        let toB = AccountIdentity(uuid: "B", email: "b@example.com")
        let merged = UsageService.merge(
            previous: ["p": onA],
            result: UsageRefreshResult(
                accounts: [],
                bindingFailures: ["p": .keychainUnavailable(.interactionNotAllowed)],
                hintedAccounts: ["p": toB]
            )
        )
        #expect(merged["p"]?.identity.email == "b@example.com")
        #expect(merged["p"]?.snapshot == nil)
    }

    @Test
    func anExpiredPhantomDropsFiguresItFetchedUnderItsFingerprint() {
        // A phantom is usually figureless — but a token whose `/profile` lookup keeps failing still
        // fetches usage and stores it under the *fingerprint*, so once that token expires the
        // phantom is served those samples. They belong to whatever login the token held, which the
        // hint is only guessing at, and an expired-token row shows no figures either way.
        var withFigures = phantom("stale")
        withFigures.snapshot = snapshot(0.9)
        let merged = UsageService.merge(
            previous: [:],
            result: UsageRefreshResult(
                accounts: [withFigures],
                bindingFailures: [:],
                hintedAccounts: ["stale": acct]
            )
        )
        #expect(merged["stale"]?.identity.email == "a@example.com")
        #expect(merged["stale"]?.snapshot == nil)
    }

    @Test
    func aSignedOutBindingDoesNotRejoinItsAccountOnAKeychainRefusal() {
        // The inverse of `carriedReason`, and the hole a hint opens if attachment only looks at
        // *this* pass's failure. The profile signed out; the next poll cannot read the keychain,
        // which says nothing about whether it is signed in — so the hint would put it back on the
        // login and hand it the live sibling's quota bars, on a row whose last positive knowledge
        // was that it holds none. The refusal is still what the row *says* (it is current and
        // actionable); it is the membership and the figures that must not come back.
        let out = account(
            uuid: "A", email: "a@example.com", snapshot: nil,
            state: .noSource(.signedOut), bindingIDs: ["out"]
        )
        let live = account(uuid: "A", email: "a@example.com", snapshot: snapshot(0.6), bindingIDs: ["live"])
        let refused = TokenProviderError.keychainUnavailable(.interactionNotAllowed)
        let merged = UsageService.merge(
            previous: ["out": out],
            result: UsageRefreshResult(
                accounts: [live],
                bindingFailures: ["out": refused],
                hintedAccounts: ["out": acct]
            )
        )
        #expect(merged["out"]?.snapshot == nil)
        #expect(merged["out"]?.bindingIDs == ["out"])
        #expect(merged["live"]?.bindingIDs == ["live"])
        #expect(merged["out"]?.state == .noSource(refused))
    }

    // MARK: - What a hint may never do

    @Test
    func aBindingThatResolvedOnItsOwnIsUntouched() {
        let live = account(uuid: "A", email: "a@example.com", snapshot: snapshot(0.6), bindingIDs: ["p"])
        let merged = UsageService.merge(
            previous: [:],
            result: UsageRefreshResult(
                accounts: [live],
                bindingFailures: [:],
                hintedAccounts: ["p": AccountIdentity(uuid: "B", email: "b@example.com")]
            )
        )
        #expect(merged["p"] == live)
    }

    @Test
    func attachmentsNeverChainOffOneAnother() {
        // Donors are read from the pass's own accounts, never from the map being built. Otherwise a
        // pass where *nothing* resolved would have every entry repainting every other from stale
        // copies, and the figures shown would depend on dictionary iteration order.
        let carried = ["one": snapshot(0.1), "two": snapshot(0.2), "three": snapshot(0.3)]
        let previous = carried.mapValues {
            account(uuid: "A", email: "a@example.com", snapshot: $0, bindingIDs: ["x"])
        }
        let failures = carried.keys.reduce(into: [String: TokenProviderError]()) {
            $0[$1] = .malformedCache
        }
        let hints = carried.keys.reduce(into: [String: AccountIdentity]()) { $0[$1] = acct }
        let merged = UsageService.merge(
            previous: previous,
            result: UsageRefreshResult(accounts: [], bindingFailures: failures, hintedAccounts: hints)
        )
        for (id, own) in carried {
            #expect(merged[id]?.snapshot == own, "\(id) borrowed from a sibling")
        }
    }
}
