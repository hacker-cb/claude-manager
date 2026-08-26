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

        // A dotted-numeric marketing version, the form `VersionOrder` compares.
        #expect(
            update.version.range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil,
            "unexpected version format: \(update.version)"
        )

        // The installer takes a zip with `Claude.app` at its top level; a switch to another
        // container would need code, not just a new URL, so fail loudly here.
        #expect(
            update.downloadURL.pathExtension.lowercased() == "zip",
            "download is no longer a .zip: \(update.downloadURL)"
        )
        #expect(update.downloadURL.scheme?.lowercased() == "https")

        // Not an assertion — the feed legitimately moves ahead of what was verified by
        // hand. It is a note in the log for whoever is looking at a failure above.
        if update.version != CoreConstants.claudeReleaseFeedValidatedVersion {
            Comment.record("""
            feed now offers \(update.version); \
            contract last verified against \(CoreConstants.claudeReleaseFeedValidatedVersion)
            """)
        }
    }
}

private extension Comment {
    static func record(_ message: String) {
        Issue.record(Comment(rawValue: message), sourceLocation: #_sourceLocation)
    }
}
