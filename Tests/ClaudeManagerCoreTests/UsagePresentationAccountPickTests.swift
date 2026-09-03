import Foundation
import Testing
@testable import ClaudeManagerCore

/// `UsagePresentation.onePerAccount` — which entry speaks for a login on a surface that lists
/// **accounts** rather than profiles.
///
/// An extension in its own file: the suite body is near the `type_body_length` limit, and these
/// tests build their own values rather than reaching for the main file's private builders.
extension UsagePresentationTests {
    private func entry(
        uuid: String,
        email: String? = nil,
        state: UsageState = .fresh,
        hasFigures: Bool = false,
        bindingIDs: [String]
    ) -> AccountUsage {
        AccountUsage(
            identity: AccountIdentity(uuid: uuid, email: email),
            snapshot: hasFigures ? UsageSnapshot(limits: []) : nil,
            state: state,
            bindingIDs: bindingIDs
        )
    }

    @Test
    func aReadableSiblingOutranksOneWaitingOnAPerson() {
        // Equal fan-out and neither `.fresh`: one binding's token failed to resolve while another
        // came back offline with figures still on it. A single `.fresh` test left both on the
        // same rung, so the tie fell to the lowest id — and the lexicographically earlier failure
        // carried `.needsAttention` into the ranking while the sibling's perfectly readable
        // retained snapshot went unused.
        let failed = entry(
            uuid: "A", state: .noSource(.signedOut), bindingIDs: ["aaa", "zzz"]
        )
        let readable = entry(uuid: "A", state: .offline, bindingIDs: ["aaa", "zzz"])
        let picked = UsagePresentation.onePerAccount(["aaa": failed, "zzz": readable])
        #expect(picked.count == 1)
        #expect(picked.first?.state == .offline)
    }

    @Test
    func figuresOutrankFreshnessWhenOnlyOneSideHasThem() {
        // `.fresh` is not a promise of figures: the service reports "current with nothing yet"
        // for a binding whose history is empty or unreadable. Ranking freshness above their
        // *presence* put such an entry ahead of an offline sibling holding real numbers, and the
        // login then read as "not checked yet" while another binding could have shown its week.
        let freshButEmpty = entry(uuid: "A", bindingIDs: ["aaa", "zzz"])
        let offlineWithFigures = entry(
            uuid: "A", state: .offline, hasFigures: true, bindingIDs: ["aaa", "zzz"]
        )
        let picked = UsagePresentation.onePerAccount(["aaa": freshButEmpty, "zzz": offlineWithFigures])
        #expect(picked.count == 1)
        #expect(picked.first?.snapshot != nil)
    }

    @Test
    func freshnessStillDecidesWhenNeitherSideHasFigures() {
        // The third question is only reached once the second is a tie — and there it still
        // answers, since a fresh binding is the one the next pass will fill.
        let offline = entry(uuid: "A", state: .offline, bindingIDs: ["aaa", "zzz"])
        let fresh = entry(uuid: "A", bindingIDs: ["aaa", "zzz"])
        let picked = UsagePresentation.onePerAccount(["aaa": offline, "zzz": fresh])
        #expect(picked.first?.state == .fresh)
    }

    @Test
    func aFreshSiblingStillOutranksAReadableOne() {
        // The top rung survives the middle one being added.
        let offline = entry(uuid: "A", state: .offline, bindingIDs: ["aaa", "zzz"])
        let fresh = entry(uuid: "A", bindingIDs: ["aaa", "zzz"])
        let picked = UsagePresentation.onePerAccount(["aaa": offline, "zzz": fresh])
        #expect(picked.first?.state == .fresh)
    }

    @Test
    func fanOutStillBeatsUsefulness() {
        // Usefulness only settles a tie: a fresh row speaking for itself alone must not displace
        // an offline one speaking for the whole login.
        let wide = entry(uuid: "A", state: .offline, bindingIDs: ["aaa", "zzz"])
        let narrow = entry(uuid: "A", bindingIDs: ["zzz"])
        let picked = UsagePresentation.onePerAccount(["aaa": wide, "zzz": narrow])
        #expect(picked.first?.bindingIDs.count == 2)
    }

    @Test
    func aDetachedRowNeverSpeaksForALoginThatStillHasMembers() {
        // The Doctor inspector lists logins, so it picks one entry per uuid — and it used to take
        // whichever `Dictionary.values` yielded first, an order Swift reseeds every process. A
        // signed-out binding keeps its account's uuid while holding only itself in `bindingIDs`, so
        // the coin flip could name a live login after the profile that left it.
        let live = entry(uuid: "A", email: "a@example.com", bindingIDs: ["live-one", "live-two"])
        let detached = entry(
            uuid: "A",
            email: "a@example.com",
            state: .noSource(.signedOut),
            bindingIDs: ["gone"]
        )
        // "gone" sorts before both live ids, so merely making the pick *stable* — first wins over
        // sorted keys — would still take the wrong member. Fan-out width is what settles it.
        let picked = UsagePresentation.onePerAccount([
            "gone": detached, "live-one": live, "live-two": live
        ])
        #expect(picked == [live])
    }

    @Test
    func eachLoginIsRepresentedOnceAndInAStableOrder() {
        let byBinding = [
            "b": entry(uuid: "B", bindingIDs: ["b"]),
            "a": entry(uuid: "A", bindingIDs: ["a"]),
            "c": entry(uuid: "A", bindingIDs: ["c"])
        ]
        let picked = UsagePresentation.onePerAccount(byBinding)
        // Two logins out of three bindings, ordered by uuid. Neither "A" member has a wider fan-out
        // than the other, so the tie falls to the lower binding id — a rule, not a hash seed.
        #expect(picked.map(\.identity.uuid) == ["A", "B"])
        #expect(picked.first?.bindingIDs == ["a"])
    }

    @Test
    func aLoginWhoseOnlyProfileSignedOutIsStillListed() {
        // The pick prefers a wider fan-out, but it must not *drop* anything: a login every profile
        // has left is exactly the one whose stored `/usage` body a person opens the inspector to
        // look at.
        let alone = entry(uuid: "A", state: .noSource(.signedOut), bindingIDs: ["gone"])
        #expect(UsagePresentation.onePerAccount(["gone": alone]) == [alone])
    }
}
