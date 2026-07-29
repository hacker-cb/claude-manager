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
        bindingIDs: [String]
    ) -> AccountUsage {
        AccountUsage(
            identity: AccountIdentity(uuid: uuid, email: email),
            snapshot: nil,
            state: state,
            bindingIDs: bindingIDs
        )
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
