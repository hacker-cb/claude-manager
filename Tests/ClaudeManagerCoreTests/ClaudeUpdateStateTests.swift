import Foundation
import Testing
@testable import ClaudeManagerCore

/// The update state machine and its check schedule.
///
/// Both live in the core rather than beside the view precisely so they can be tested: the
/// app target has no test suite, and "when do we ask again" is exactly the kind of rule that
/// is wrong in one direction for months without anyone noticing.
struct ClaudeUpdateStateTests {
    private let update = AvailableUpdate(
        version: "1.37937.1",
        downloadURL: URL(string: "https://downloads.claude.ai/a.zip")!
    )
    private let verified = VerifiedUpdate(
        version: "1.37937.1",
        appURL: URL(fileURLWithPath: "/tmp/staged/Claude.app")
    )

    // MARK: - What the state says about itself

    @Test
    func reportsTheVersionItIsAbout() {
        #expect(ClaudeUpdateState.idle.version == nil)
        #expect(ClaudeUpdateState.available(update).version == "1.37937.1")
        #expect(ClaudeUpdateState.downloading(version: "1.2.3", received: 1, total: 2).version == "1.2.3")
        #expect(ClaudeUpdateState.ready(verified).version == "1.37937.1")
        #expect(ClaudeUpdateState.installing(version: "1.2.3").version == "1.2.3")
        #expect(ClaudeUpdateState.failed(reason: "nope").version == nil)
    }

    /// `isBusy` gates the controls that would start more work.
    @Test
    func knowsWhenWorkIsInFlight() {
        #expect(ClaudeUpdateState.downloading(version: "1.2.3", received: 0, total: nil).isBusy)
        #expect(ClaudeUpdateState.installing(version: "1.2.3").isBusy)
        #expect(!ClaudeUpdateState.idle.isBusy)
        #expect(!ClaudeUpdateState.available(update).isBusy)
        #expect(!ClaudeUpdateState.ready(verified).isBusy)
        #expect(!ClaudeUpdateState.failed(reason: "nope").isBusy)
    }

    // MARK: - When to ask again

    /// A prepared build already holds the news, and a check that replaced it would throw
    /// away a finished download.
    @Test
    func doesNotCheckOverAPreparedOrInFlightBuild() {
        #expect(!ClaudeUpdateState.ready(verified).allowsCheck)
        #expect(!ClaudeUpdateState.downloading(version: "1.2.3", received: 0, total: nil).allowsCheck)
        #expect(!ClaudeUpdateState.installing(version: "1.2.3").allowsCheck)
    }

    /// The one that matters: a transient network error must not become a permanent stop.
    @Test
    func keepsCheckingAfterAFailure() {
        #expect(ClaudeUpdateState.failed(reason: "offline").allowsCheck)
        #expect(ClaudeUpdateState.idle.allowsCheck)
        #expect(ClaudeUpdateState.available(update).allowsCheck)
    }

    @Test
    func checksImmediatelyWhenNothingHasBeenCheckedYet() {
        #expect(ClaudeUpdateState.isCheckDue(lastCheck: nil, now: Date(), interval: 3600))
    }

    @Test
    func waitsOutTheInterval() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(!ClaudeUpdateState.isCheckDue(
            lastCheck: now.addingTimeInterval(-3599), now: now, interval: 3600
        ))
        #expect(ClaudeUpdateState.isCheckDue(
            lastCheck: now.addingTimeInterval(-3600), now: now, interval: 3600
        ))
    }

    /// A timestamp in the future means the clock moved backwards — a timezone change, or a
    /// machine that woke with a bad time. Waiting out an interval measured from a future that
    /// never happened could mean waiting indefinitely.
    @Test
    func checksWhenTheRecordedTimeIsInTheFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ClaudeUpdateState.isCheckDue(
            lastCheck: now.addingTimeInterval(86400), now: now, interval: 3600
        ))
    }

    // MARK: - The line the settings row and the menu both read

    @Test
    func describesWorkInFlightByItsVersion() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let line = { (state: ClaudeUpdateState) in state.statusLine(lastSuccess: now, now: now) }
        #expect(line(.available(update)) == "Claude 1.37937.1 is available, not downloaded yet.")
        #expect(line(.downloading(version: "1.2.3", received: 1, total: 2)) == "Downloading Claude 1.2.3…")
        #expect(line(.ready(verified)) == "Claude 1.37937.1 is ready to install.")
        #expect(line(.installing(version: "1.2.3")) == "Installing Claude 1.2.3…")
        #expect(line(.failed(reason: "offline")) == "Update failed: offline")
    }

    /// Idle is the state a *failed* background check also leaves behind, so the line falls
    /// back to when the feed last answered — the one reading that can tell "up to date" apart
    /// from "nothing has reached Anthropic in a week".
    @Test
    func fallsBackToWhenTheFeedLastAnswered() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ClaudeUpdateState.idle.statusLine(lastSuccess: nil, now: now) == "Not checked yet.")
        #expect(
            ClaudeUpdateState.idle.statusLine(lastSuccess: now.addingTimeInterval(-30), now: now)
                == "Last successful check just now."
        )
        #expect(
            ClaudeUpdateState.idle.statusLine(lastSuccess: now.addingTimeInterval(-3 * 86400), now: now)
                == "Last successful check 3 d ago."
        )
    }

    /// The stamp is only consulted when nothing is happening: a download in flight is news
    /// about *now*, and pairing it with "last checked 3 days ago" reads as a contradiction.
    @Test
    func ignoresTheStampWhileSomethingIsHappening() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stale = now.addingTimeInterval(-9 * 86400)
        #expect(
            ClaudeUpdateState.ready(verified).statusLine(lastSuccess: stale, now: now)
                == ClaudeUpdateState.ready(verified).statusLine(lastSuccess: nil, now: now)
        )
    }
}
