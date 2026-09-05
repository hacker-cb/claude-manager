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
        #expect(UpdateNews.hasNews(claude: .ready(verified), manager: .available(version: "0.16.0")))
    }

    // MARK: - The version printed beside the icon

    /// Only the prepared Claude build, which is the one state that waits indefinitely.
    @Test
    func printsAVersionOnlyForAPreparedClaudeBuild() {
        #expect(UpdateNews.buttonLabel(claude: .ready(verified)) == "1.37937.1")
        #expect(UpdateNews.buttonLabel(claude: .available(update)) == nil)
        #expect(UpdateNews.buttonLabel(claude: .downloading(version: "1.2.3", received: 1, total: 2)) == nil)
        #expect(UpdateNews.buttonLabel(claude: .installing(version: "1.2.3")) == nil)
        #expect(UpdateNews.buttonLabel(claude: .failed(reason: "nope")) == nil)
        #expect(UpdateNews.buttonLabel(claude: .idle) == nil)
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

    @Test
    func reportsTheReleaseItIsAbout() {
        #expect(ManagerUpdateState.idle.version == nil)
        #expect(ManagerUpdateState.available(version: "0.16.0").version == "0.16.0")
        #expect(ManagerUpdateState.available(version: "0.16.0")
            .statusLine == "Claude Manager 0.16.0 is available.")
        #expect(ManagerUpdateState.idle.statusLine.isEmpty)
    }
}
