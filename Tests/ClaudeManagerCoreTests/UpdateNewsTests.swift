import Foundation
import Testing
@testable import ClaudeManagerCore

/// What the window's one update control says when there are two updaters behind it.
///
/// The rules live in the core for the reason every rule here does: the app target has no test
/// suite, and "which of the two gets to print its version in the toolbar" is exactly the sort
/// of decision that drifts silently once it is spelled inside a `switch` in a view.
struct UpdateNewsTests {
    private let update = AvailableUpdate(
        version: "1.37937.1",
        downloadURL: URL(string: "https://downloads.claude.ai/a.zip")!
    )
    private let verified = VerifiedUpdate(
        version: "1.37937.1",
        appURL: URL(fileURLWithPath: "/tmp/staged/Claude.app")
    )

    // MARK: - Whether the control is shown at all

    @Test
    func saysNothingWhenBothUpdatersAreIdle() {
        #expect(!UpdateNews.hasNews(claude: .idle, manager: .idle))
    }

    /// Either one on its own is enough: the control is shared, and a Sparkle release is news
    /// even on a machine whose Claude is current.
    @Test
    func speaksForEitherUpdaterAlone() {
        #expect(UpdateNews.hasNews(claude: .available(update), manager: .idle))
        #expect(UpdateNews.hasNews(claude: .idle, manager: .available(version: "0.16.0")))
        #expect(UpdateNews.hasNews(claude: .idle, manager: .downloaded(version: "0.16.0")))
        #expect(UpdateNews.hasNews(claude: .ready(verified), manager: .available(version: "0.16.0")))
    }

    // MARK: - The version printed beside the icon

    /// A prepared build earns the label — the one state that waits indefinitely — and every
    /// state that moves on its own or is answered by opening the panel does not.
    @Test
    func printsAVersionOnlyForAPreparedBuild() {
        let label = { (claude: ClaudeUpdateState) in UpdateNews.buttonLabel(claude: claude, manager: .idle) }
        #expect(label(.ready(verified)) == "1.37937.1")
        #expect(label(.available(update)) == nil)
        #expect(label(.downloading(version: "1.2.3", received: 1, total: 2)) == nil)
        #expect(label(.installing(version: "1.2.3")) == nil)
        #expect(label(.failed(reason: "nope")) == nil)
        #expect(label(.idle) == nil)
    }

    /// The manager's staged build is prepared in exactly the same sense, and gets the same
    /// treatment: a release merely *found* does not, since pressing that one only opens a
    /// window which asks again.
    @Test
    func printsTheManagersVersionOnlyOnceItIsStaged() {
        #expect(
            UpdateNews.buttonLabel(claude: .idle, manager: .downloaded(version: "0.16.0")) == "0.16.0"
        )
        #expect(UpdateNews.buttonLabel(claude: .idle, manager: .available(version: "0.16.0")) == nil)
    }

    /// Two prepared builds print nothing at all. Either number alone would be read as the
    /// other's, and both together read as one number that changed — the panel is where each
    /// release gets its name.
    @Test
    func printsNothingWhenBothAppsAreWaiting() {
        #expect(
            UpdateNews.buttonLabel(claude: .ready(verified), manager: .downloaded(version: "0.16.0")) == nil
        )
        // One waiting, the other merely available: still exactly one press pending, so the
        // label stands.
        #expect(
            UpdateNews.buttonLabel(claude: .ready(verified), manager: .available(version: "0.16.0"))
                == "1.37937.1"
        )
    }

    // MARK: - The tooltip

    @Test
    func namesEveryUpdaterWithSomethingToSay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let help = UpdateNews.help(
            claude: .ready(verified),
            manager: .available(version: "0.16.0"),
            lastSuccess: now,
            now: now
        )
        #expect(help == "Claude 1.37937.1 is ready to install. Claude Manager 0.16.0 is available.")
    }

    /// An idle updater contributes nothing — not "last checked 4 h ago", which is a fact for
    /// the Settings row and noise beside a release someone is about to install.
    @Test
    func leavesAnIdleUpdaterOutOfTheLine() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let lastSuccess = now.addingTimeInterval(-14400)
        #expect(
            UpdateNews.help(
                claude: .idle,
                manager: .available(version: "0.16.0"),
                lastSuccess: lastSuccess,
                now: now
            )
                == "Claude Manager 0.16.0 is available."
        )
        #expect(
            UpdateNews.help(
                claude: .available(update),
                manager: .idle,
                lastSuccess: lastSuccess,
                now: now
            )
                == "Claude 1.37937.1 is available, not downloaded yet."
        )
        #expect(
            UpdateNews.help(claude: .idle, manager: .idle, lastSuccess: lastSuccess, now: now) == ""
        )
    }

    // MARK: - The manager's own state

    /// The record is what survives a relaunch — Sparkle asks its feed once a day and this app
    /// deliberately does not ask on its behalf, so without it a release found on Monday is
    /// forgotten by Tuesday's launch.
    @Test
    func remembersAReleaseThisBuildHasNotCaughtUpWith() {
        #expect(
            ManagerUpdateState.restored(version: "0.16.0", build: "64", installedBuild: "63")
                == .available(version: "0.16.0")
        )
    }

    /// The build number decides, and the marketing version is only what gets printed. A
    /// re-dispatched tag ships the same `0.16.0` at a higher CI run number, which Sparkle
    /// offers as an update — comparing the marketing versions would throw it away.
    @Test
    func judgesByTheBuildNumberAndPrintsTheMarketingVersion() {
        #expect(
            ManagerUpdateState.restored(version: "0.16.0", build: "64", installedBuild: "63")
                == .available(version: "0.16.0")
        )
        #expect(ManagerUpdateState.restored(version: "0.16.0", build: "63", installedBuild: "63") == .idle)
    }

    /// Every way the record can be stale or unusable answers `.idle`: an offer to install what
    /// is already running is worse than no offer at all.
    @Test
    func dropsARecordThatIsNoLongerNews() {
        #expect(ManagerUpdateState.restored(version: "0.15.0", build: "62", installedBuild: "63") == .idle)
        #expect(ManagerUpdateState.restored(version: nil, build: "64", installedBuild: "63") == .idle)
        #expect(ManagerUpdateState.restored(version: "0.16.0", build: nil, installedBuild: "63") == .idle)
        #expect(ManagerUpdateState.restored(version: "0.16.0", build: "64", installedBuild: nil) == .idle)
        // An unreadable baseline is not a licence to offer anything: `isUpgrade` answers false
        // for a version it cannot compare, and this follows it rather than guessing.
        #expect(ManagerUpdateState.restored(version: "0.16.0", build: "64", installedBuild: "") == .idle)
    }

    @Test
    func reportsTheReleaseItIsAbout() {
        #expect(ManagerUpdateState.idle.version == nil)
        #expect(ManagerUpdateState.available(version: "0.16.0").version == "0.16.0")
        #expect(ManagerUpdateState.downloaded(version: "0.16.0").version == "0.16.0")
        #expect(ManagerUpdateState.available(version: "0.16.0")
            .statusLine == "Claude Manager 0.16.0 is available.")
        #expect(ManagerUpdateState.downloaded(version: "0.16.0")
            .statusLine == "Claude Manager 0.16.0 is ready to install.")
        #expect(ManagerUpdateState.idle.statusLine.isEmpty)
    }

    /// Only a staged build waits on a press. A release merely found is answered by opening
    /// Sparkle's window, which asks again — so it is not the same kind of standing offer.
    @Test
    func knowsWhichStateIsWaitingOnAPress() {
        #expect(ManagerUpdateState.downloaded(version: "0.16.0").isWaitingForAPress)
        #expect(!ManagerUpdateState.available(version: "0.16.0").isWaitingForAPress)
        #expect(!ManagerUpdateState.idle.isWaitingForAPress)
    }

    /// A staged build is never restored from the record: the handler that installs it dies
    /// with the session Sparkle handed it to, so the offer comes back as `.available` — whose
    /// press opens the window that finds the staged build anyway.
    @Test
    func neverRestoresAStagedBuild() {
        #expect(
            ManagerUpdateState.restored(version: "0.16.0", build: "64", installedBuild: "63")
                == .available(version: "0.16.0")
        )
    }
}
