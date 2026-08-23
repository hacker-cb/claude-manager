import Foundation
import Testing
@testable import ClaudeManagerCore

/// The window decides *when* an unattended apply may be attempted — it never decides whether
/// a profile may be closed (Claude vetoes that itself). These cover the boundaries, because
/// a window that is wrong by a minute either fires at the wrong time or never fires.
struct AutoApplyWindowTests {
    /// A fixed calendar/timezone so the tests don't move with the machine's locale.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func time(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: hour, minute: minute))!
    }

    @Test
    func containsIsStartInclusiveAndEndExclusive() {
        // So two adjacent windows can't both claim the same minute.
        let window = AutoApplyWindow(startMinutes: 4 * 60, endMinutes: 6 * 60)
        #expect(window.contains(time(4, 0), calendar: calendar))
        #expect(window.contains(time(5, 59), calendar: calendar))
        #expect(!window.contains(time(6, 0), calendar: calendar))
        #expect(!window.contains(time(3, 59), calendar: calendar))
    }

    @Test
    func supportsAWindowThatCrossesMidnight() {
        // 22:00–02:00 is the shape a night-time window naturally takes, and the one a naive
        // `start...end` range gets silently wrong.
        let window = AutoApplyWindow(startMinutes: 22 * 60, endMinutes: 2 * 60)
        #expect(window.contains(time(22, 0), calendar: calendar))
        #expect(window.contains(time(23, 30), calendar: calendar))
        #expect(window.contains(time(0, 15), calendar: calendar))
        #expect(window.contains(time(1, 59), calendar: calendar))
        #expect(!window.contains(time(2, 0), calendar: calendar))
        #expect(!window.contains(time(12, 0), calendar: calendar))
    }

    @Test
    func namesAnEmptyWindowAsSuch() {
        // The settings pickers bind each end independently, so this is reachable — and a
        // feature switched on that can never run needs to say so rather than be substituted.
        #expect(AutoApplyWindow(startMinutes: 3 * 60, endMinutes: 3 * 60).isEmpty)
        #expect(!AutoApplyWindow.suggested.isEmpty)
        #expect(!AutoApplyWindow(startMinutes: 22 * 60, endMinutes: 2 * 60).isEmpty)
    }

    @Test
    func anEmptyWindowAdmitsNothing() {
        // The alternative reading — an empty range meaning "all day" — would turn a mis-set
        // window into "apply at any moment", which is the surprise this feature exists to
        // prevent.
        let window = AutoApplyWindow(startMinutes: 3 * 60, endMinutes: 3 * 60)
        #expect(!window.contains(time(3, 0), calendar: calendar))
        #expect(!window.contains(time(15, 0), calendar: calendar))
    }

    @Test
    func foldsAnOutOfRangeStoredValueOntoARealMinute() {
        // A value from a future build, or a hand-edited preference, must still describe a
        // window that can open rather than one that never does.
        #expect(AutoApplyWindow(startMinutes: 25 * 60, endMinutes: -60).startMinutes == 60)
        #expect(AutoApplyWindow(startMinutes: 25 * 60, endMinutes: -60).endMinutes == 23 * 60)
    }

    @Test
    func describesItselfForTheSettingsSummary() {
        #expect(AutoApplyWindow.suggested.displayText == "04:00–06:00")
        #expect(AutoApplyWindow(startMinutes: 22 * 60 + 5, endMinutes: 90).displayText == "22:05–01:30")
    }

    @Test
    func theSuggestedWindowIsTheNightOne() {
        // Late enough that the machine is usually idle, early enough that the profiles are
        // back before morning.
        #expect(AutoApplyWindow.suggested.contains(time(4, 30), calendar: calendar))
        #expect(!AutoApplyWindow.suggested.contains(time(9, 0), calendar: calendar))
    }

    // MARK: - The decision

    /// Every input satisfied, so only the condition under test differs in each case below.
    private func decide(
        enabled: Bool = true,
        applyInFlight: Bool = false,
        hasStagedUpdate: Bool = true,
        window: AutoApplyWindow = .suggested,
        at hour: Int = 4,
        idleSeconds: TimeInterval = 900,
        lastFailedAttempt: Date? = nil
    ) -> AutoApplyDecision {
        AutoApplyDecision.decide(
            AutoApplyDecision.Inputs(
                enabled: enabled,
                applyInFlight: applyInFlight,
                hasStagedUpdate: hasStagedUpdate,
                window: window,
                now: time(hour, 30),
                idleSeconds: idleSeconds,
                minimumIdleSeconds: 600,
                lastFailedAttempt: lastFailedAttempt
            ),
            calendar: calendar
        )
    }

    @Test
    func appliesWhenEveryConditionHolds() {
        #expect(decide() == .apply)
    }

    @Test
    func offByDefaultMeansOffInFact() {
        // The one condition the user controls, and the one that must never be inferred.
        #expect(decide(enabled: false) == .skip(.disabled))
    }

    @Test
    func neverStartsASecondApplyOverALiveSwap() {
        #expect(decide(applyInFlight: true) == .skip(.applyInFlight))
    }

    @Test
    func doesNothingWithNothingStaged() {
        #expect(decide(hasStagedUpdate: false) == .skip(.nothingStaged))
    }

    @Test
    func staysOutOfTheWayOutsideTheWindow() {
        #expect(decide(at: 13) == .skip(.outsideWindow))
    }

    @Test
    func waitsWhileSomeoneIsAtTheKeyboard() {
        // A courtesy check — it keeps windows from being yanked away mid-click. It says
        // nothing about an autonomous session; Claude's quit veto is what catches those.
        #expect(decide(idleSeconds: 120) == .skip(.userIsPresent))
        #expect(decide(idleSeconds: 600) == .apply, "the threshold itself counts as idle")
    }

    @Test
    func reportsTheMostInformativeReasonWhenSeveralApply() {
        // With the feature off *and* the wrong time of day, "you haven't enabled this" is the
        // answer worth logging — not "the Mac isn't idle".
        #expect(decide(enabled: false, hasStagedUpdate: false, at: 13, idleSeconds: 0) == .skip(.disabled))
    }

    @Test
    func backsOffAfterAFailedAttemptOnTheSameVersion() {
        // The failure this guards is a profile vetoing its quit because it is working — with
        // nobody there to resolve it. Without the back-off the tick retries every minute for
        // the rest of the window, closing and reopening every *other* profile each time and
        // re-prompting the busy one.
        let justFailed = time(4, 25)
        #expect(decide(lastFailedAttempt: justFailed) == .skip(.backingOffAfterFailure))
    }

    @Test
    func triesAgainOnceTheBackOffHasElapsed() {
        let longAgo = time(4, 30).addingTimeInterval(-AutoApplyDecision.retryBackoff - 60)
        #expect(decide(lastFailedAttempt: longAgo) == .apply)
    }

    @Test
    func presenceIsCheckedBeforeTheBackOff() {
        // Someone at the keyboard is the more actionable reason to report, and the back-off
        // record is version-scoped state that means nothing if we weren't going to try anyway.
        #expect(decide(idleSeconds: 5, lastFailedAttempt: time(4, 25)) == .skip(.userIsPresent))
    }

    @Test
    func aFailureTimestampInTheFutureIsIgnored() {
        // A clock moved back, or preferences restored from another machine, would otherwise
        // make the elapsed time negative and hold the back-off until the wall clock caught
        // up — skipping windows for days. A bad clock costs one extra attempt at most.
        let future = time(4, 30).addingTimeInterval(48 * 3600)
        #expect(decide(lastFailedAttempt: future) == .apply)
    }

    // MARK: - Offering to enable it

    @Test
    func staysQuietUntilTheUpdateHasActuallyBeenStuck() {
        // Most updates are applied within minutes of the banner appearing. Suggesting at
        // download time would put a prompt in front of everyone, for a problem almost nobody
        // has yet.
        #expect(!AutoApplyDecision.shouldOfferEnabling(alreadyEnabled: false, answered: false, waited: 0))
        #expect(!AutoApplyDecision.shouldOfferEnabling(
            alreadyEnabled: false, answered: false, waited: 12 * 3600
        ))
    }

    @Test
    func offersOnceAFullDayHasPassed() {
        // A full day, not twelve hours: the offer's premise is "this could already have been
        // installed for you", and only a whole day makes that true whatever time the update
        // arrived — twelve hours from a 07:00 sighting is 19:00, with no night-time window
        // having come round at all.
        #expect(AutoApplyDecision.shouldOfferEnabling(
            alreadyEnabled: false, answered: false, waited: AutoApplyDecision.stuckThreshold
        ))
        #expect(AutoApplyDecision.shouldOfferEnabling(
            alreadyEnabled: false, answered: false, waited: 70 * 3600
        ))
    }

    @Test
    func neverOffersWhatIsAlreadyOn() {
        #expect(!AutoApplyDecision.shouldOfferEnabling(
            alreadyEnabled: true, answered: false, waited: 70 * 3600
        ))
    }

    @Test
    func takesNoForAnAnswer() {
        // The population this targets is the one whose update never applies, so "it goes away
        // when the update installs" is no answer for them — without a remembered no, the offer
        // would reappear at every launch for days.
        #expect(!AutoApplyDecision.shouldOfferEnabling(
            alreadyEnabled: false, answered: true, waited: 70 * 3600
        ))
    }
}
