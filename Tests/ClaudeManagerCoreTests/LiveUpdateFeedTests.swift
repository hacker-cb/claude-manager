import Foundation
import Testing
@testable import ClaudeManagerCore

/// Checks the **real** release endpoint still answers in the shape ``UpdateFeed`` parses.
///
/// Opt-in (`CLAUDE_MANAGER_LIVE=1`) because it needs the network, and kept apart from the
/// unit tests for a second reason: it is the only thing that can notice Anthropic reshaping
/// an API they never documented. `UpdateFeedTests` pins the parser to a payload captured by
/// hand; this pins that payload to reality. Read-only — it fetches ~150 bytes of JSON and
/// never downloads a build.
struct LiveUpdateFeedTests {
    static var live: Bool {
        ProcessInfo.processInfo.environment["CLAUDE_MANAGER_LIVE"] == "1"
    }

    @Test(.enabled(if: LiveUpdateFeedTests.live))
    func theRealEndpointStillAnswersInTheExpectedShape() async throws {
        let update = try await UpdateFeed().latest()

        // Asks the same question the parser asks, rather than a second regex of its own:
        // two definitions of "a version" are two things to keep in sync, and this test
        // exists to check the real feed against *our* contract.
        #expect(
            VersionOrder.isComparable(update.version),
            "unexpected version format: \(update.version)"
        )

        // The installer takes a zip with `Claude.app` at its top level; a switch to another
        // container would need code, not just a new URL, so fail loudly here.
        #expect(
            update.downloadURL.pathExtension.lowercased() == "zip",
            "download is no longer a .zip: \(update.downloadURL)"
        )
        #expect(update.downloadURL.scheme?.lowercased() == "https")

        // The feed legitimately moves ahead of what was verified by hand, so drift *forward*
        // is expected and must not fail: a test that has to be silenced with a constant bump
        // on every Claude release would be turned off long before the reshape it exists to
        // catch. Only a feed that has gone *backwards* from the verified build is suspicious
        // enough to fail on.
        #expect(
            VersionOrder.compare(update.version, CoreConstants.claudeReleaseFeedValidatedVersion)
                != .orderedAscending,
            """
            feed offers \(update.version), older than the \
            \(CoreConstants.claudeReleaseFeedValidatedVersion) the contract was verified against
            """
        )
    }
}
