import Foundation
import Testing
@testable import ClaudeManagerCore

/// What the UI says about a binding. These rules lived in the SwiftUI layer, which this package has
/// no test target for, so every one of them was verifiable only by reading it — and they drifted.
/// The drift each test pins is named in its comment.
struct UsagePresentationTests {
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    private func snapshot(
        resetsIn seconds: TimeInterval? = nil,
        capturedAgo: TimeInterval = 0
    ) -> UsageSnapshot {
        UsageSnapshot(
            limits: [UsageLimit(
                rawKind: UsageLimit.kindSession,
                utilization: 0.87,
                resetsAt: seconds.map { now.addingTimeInterval($0) },
                isActive: true
            )],
            capturedAt: now.addingTimeInterval(-capturedAgo)
        )
    }

    private func account(
        _ state: UsageState,
        email: String? = "a@example.com",
        snapshot: UsageSnapshot? = nil
    ) -> AccountUsage {
        AccountUsage(
            identity: AccountIdentity(uuid: "A", email: email),
            snapshot: snapshot,
            state: state,
            bindingIDs: ["p"]
        )
    }

    // MARK: - One warning classification

    @Test
    func onlyAMalfunctionIsAWarning() {
        // The sidebar used to derive its tint from `meansNotSignedIn` and the pane from its own
        // table, so `.configUnreadable` was an orange alert in one column and calm grey in the next.
        #expect(!UsagePresentation.isWarning(.signedOut))
        #expect(!UsagePresentation.isWarning(.noTokenCache))
        #expect(!UsagePresentation.isWarning(.configUnreadable))
        #expect(UsagePresentation.isWarning(.keychainUnavailable(.interactionNotAllowed)))
        #expect(UsagePresentation.isWarning(.keychainUnavailable(.notFound)))
        #expect(UsagePresentation.isWarning(.decryptFailed(.decryptFailed)))
        #expect(UsagePresentation.isWarning(.malformedCache))
        #expect(UsagePresentation.isWarning(.noUsableEntry))
    }

    @Test
    func theSidebarAndThePaneAgreeOnEveryFailure() {
        // The property the split tables could not hold: one binding, one verdict, whatever surface
        // asks. `.configUnreadable` is the case that actually diverged.
        for failure: TokenProviderError in [
            .signedOut, .noTokenCache, .configUnreadable, .malformedCache, .noUsableEntry,
            .keychainUnavailable(.interactionNotAllowed), .keychainUnavailable(.notFound),
            .decryptFailed(.decryptFailed)
        ] {
            let usage = account(.noSource(failure), snapshot: snapshot())
            let cell = UsagePresentation.attention(usage: usage, failure: failure)
            let header = UsagePresentation.headerNote(usage: usage, now: now)
            #expect(cell?.isWarning == header?.isWarning, "disagreed on \(failure)")
        }
    }

    // MARK: - Speaking without an account

    @Test
    func onlyASignOutSpeaksForABindingWithNoAccount() {
        // A launcher created and never opened has no config.json, and the default binding of a
        // launcher-only user is permanently `.noTokenCache`. Both used to raise a standing alert
        // that no action clears.
        #expect(UsagePresentation.attention(usage: nil, failure: .signedOut) != nil)
        #expect(UsagePresentation.attention(usage: nil, failure: .configUnreadable) == nil)
        #expect(UsagePresentation.attention(usage: nil, failure: .noTokenCache) == nil)
        #expect(UsagePresentation.attention(usage: nil, failure: .keychainUnavailable(.notFound)) == nil)
        #expect(UsagePresentation.attention(usage: nil, failure: nil) == nil)
        #expect(UsagePresentation.accountLine(usage: nil, failure: .configUnreadable) == nil)
        #expect(UsagePresentation.accountLine(usage: nil, failure: .signedOut) == "Signed out")
    }

    @Test
    func aSignedOutBindingWithNoAccountStillReachesTheCompactSurfaces() {
        // The cold start the second source exists for: signed out before the app launched, so no
        // pass ever produces an account to carry the reason.
        let attention = UsagePresentation.attention(usage: nil, failure: .signedOut)
        #expect(attention?.word == "Sign in")
        #expect(attention?.isWarning == false)
        #expect(UsagePresentation.attentionNote(usage: nil, failure: .signedOut) == "signed out")
    }

    // MARK: - The account line

    @Test
    func aSignedOutRowNamesTheStateAndKeepsTheFormerLoginAsPastTense() {
        // No snapshot, deliberately: the fold strips a signed-out binding's figures, so this is the
        // shape the line actually has to render. The e-mail is the whole of what survives, and it
        // is the most useful thing on the row for telling two profiles apart.
        let usage = account(.noSource(.signedOut))
        #expect(UsagePresentation.accountLine(usage: usage, failure: .signedOut)
            == "Signed out · was a@example.com")
    }

    @Test
    func aLoginWeMerelyCouldNotReadKeepsItsEmail() {
        // A locked keychain leaves the login in place; replacing the e-mail there would hide the
        // only thing on the row that tells two profiles apart.
        let failure = TokenProviderError.keychainUnavailable(.interactionNotAllowed)
        let usage = account(.noSource(failure), snapshot: snapshot())
        #expect(UsagePresentation.accountLine(usage: usage, failure: failure) == "a@example.com")
    }

    // MARK: - The reset countdown

    @Test
    func aResetIsPrintedOnlyWhileItsWindowIsAhead() {
        // Gating on `.fresh` was not enough: a snapshot re-served inside the poll floor, or the one
        // a "Manually only" user fetched hours ago, is `.fresh` — and `UsageFormat.resets` answers
        // "resetting…" for any elapsed window, which then ticks forever.
        #expect(UsagePresentation.showsReset(now.addingTimeInterval(600), now: now))
        #expect(!UsagePresentation.showsReset(now.addingTimeInterval(-600), now: now))
        #expect(!UsagePresentation.showsReset(nil, now: now))
    }

    // MARK: - The header note

    @Test
    func everyStateThatRendersBarsIsDated() {
        // Without an age, a day-old 87% reads as the current quota — the countdown is gone once the
        // window elapses and the state word alone says nothing about *when*.
        //
        // `.noSource(.configUnreadable)` rather than `.signedOut`: a signed-out binding no longer
        // carries figures at all, so that pairing is one the fold cannot produce and the fixture
        // would have been describing a state that does not exist.
        let old = snapshot(capturedAgo: 7200)
        for state: UsageState in [.rateLimited, .offline, .loginNeeded, .noSource(.configUnreadable)] {
            let note = UsagePresentation.headerNote(usage: account(state, snapshot: old), now: now)
            #expect(note?.text.hasSuffix("· as of 2 h ago") == true, "undated: \(state)")
        }
    }

    @Test
    func aPaneWithNoFiguresSaysItOnceInTheBodyAndNotTwice() {
        // The header dates figures. With none to date it has nothing to add that the body's own
        // sentence does not already say better, and printing a two-word version directly above the
        // sentence reads as a stutter. True of a signed-out pane now that its figures are gone, and
        // equally of a 429 on a first-ever fetch or an offline start.
        for state: UsageState in [.rateLimited, .offline, .loginNeeded, .noSource(.signedOut)] {
            #expect(
                UsagePresentation.headerNote(usage: account(state), now: now) == nil,
                "stuttered: \(state)"
            )
            #expect(
                UsagePresentation.sentence(usage: account(state), failure: nil) != nil,
                "silent: \(state)"
            )
        }
    }

    @Test
    func aBindingWithNoAccountLeavesTheHeaderToTheBody() {
        // The pane printed the same explanation twice, once above the other, when the header
        // learned to speak from a bare failure.
        #expect(UsagePresentation.headerNote(usage: nil, now: now) == nil)
        #expect(UsagePresentation.sentence(usage: nil, failure: .configUnreadable)
            == "Not set up yet — open this profile once, then Refresh.")
    }

    @Test
    func anUnreadableConfigIsNotCalledUnsetUpAboveItsOwnFigures() {
        // "not set up yet" is true of a launcher nobody opened and plainly false above a months-old
        // profile's usage bars, which a transient config.json read produces.
        let withBars = account(.noSource(.configUnreadable), snapshot: snapshot())
        #expect(UsagePresentation.headerNote(usage: withBars, now: now)?.text
            .hasPrefix("config unreadable") == true)
        // With no bars the header has nothing to date and stays quiet; the pane's body carries the
        // never-opened reading instead. The distinction itself is pinned on `stateNote`, which is
        // where it is still observable — see `theCompactPhraseSeesTheFiguresToo`.
        let withoutBars = account(.noSource(.configUnreadable))
        #expect(UsagePresentation.headerNote(usage: withoutBars, now: now) == nil)
        #expect(UsagePresentation.sentence(usage: withoutBars, failure: nil)
            == "Not set up yet — open this profile once, then Refresh.")
    }

    @Test
    func theCompactPhraseSeesTheFiguresToo() {
        // The tooltip and the menu row have to agree with the header. Constant means constant *in
        // time* — whether a snapshot exists is a property of the reading, not of the clock, so
        // consulting it costs the non-ticking tooltip nothing.
        let withBars = account(.noSource(.configUnreadable), snapshot: snapshot())
        #expect(UsagePresentation.stateNote(withBars) == "config unreadable")
        #expect(UsagePresentation.stateNote(account(.noSource(.configUnreadable))) == "not set up yet")
        #expect(UsagePresentation.attentionNote(usage: withBars, failure: .configUnreadable)
            == "config unreadable")
    }

    // MARK: - The remedy a surface names

    @Test
    func aRemedyIsNamedOnlyWhereOneExists() {
        #expect(UsagePresentation.attention(usage: account(.noSource(.signedOut)), failure: nil)?
            .word == "Sign in")
        #expect(UsagePresentation.attention(
            usage: account(.noSource(.keychainUnavailable(.interactionNotAllowed))), failure: nil
        )?.word == "Authorize")
        // A missing keychain item cannot be authorized and an unreadable cache cannot be signed
        // into — instructing there sends the user to do the one thing that cannot help.
        #expect(UsagePresentation.attention(
            usage: account(.noSource(.keychainUnavailable(.notFound))), failure: nil
        )?.word == "Unavailable")
        #expect(UsagePresentation.attention(usage: account(.noSource(.noUsableEntry)), failure: nil)?.word
            == "Unavailable")
        // A rejected token is a surprise the user did not cause, so it keeps the colour.
        #expect(UsagePresentation.attention(usage: account(.loginNeeded), failure: nil)?.isWarning == true)
        // States that print figures need no word at all.
        #expect(UsagePresentation.attention(usage: account(.fresh), failure: nil) == nil)
        #expect(UsagePresentation.attention(usage: account(.offline), failure: nil) == nil)
    }
}
