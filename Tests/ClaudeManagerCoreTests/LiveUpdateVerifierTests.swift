import Foundation
import Testing
@testable import ClaudeManagerCore

/// Runs the verifier's signing checks against the **real** `/Applications/Claude.app`.
///
/// Opt-in (`CLAUDE_MANAGER_LIVE=1`), and read-only — it inspects the installed bundle and
/// changes nothing. The unit tests stub `codesign` and `spctl`, which proves how the verifier
/// *reacts* to their answers but nothing about whether it asks them the right questions. This
/// is the other half: a genuine, notarized, Anthropic-signed bundle must pass all three, and
/// if it does not, the checks are wrong rather than the bundle.
struct LiveUpdateVerifierTests {
    static var live: Bool {
        ProcessInfo.processInfo.environment["CLAUDE_MANAGER_LIVE"] == "1"
    }

    private var installedClaude: URL? {
        let url = URL(fileURLWithPath: CoreConstants.defaultRealClaudePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test(.enabled(if: LiveUpdateVerifierTests.live))
    func theInstalledClaudePassesEverySigningCheck() throws {
        guard let claude = installedClaude else {
            Issue.record("no Claude.app at \(CoreConstants.defaultRealClaudePath)")
            return
        }
        let verifier = UpdateVerifier(runner: SystemCommandRunner())

        // Each one separately, so a failure names which question was answered wrong.
        try verifier.checkSignature(claude)
        try verifier.checkIsAnthropic(claude)
        try verifier.checkNotarized(claude)
    }

    /// The requirement has to *discriminate*, not merely pass. A requirement naming the wrong
    /// team must be refused — otherwise "signed by Anthropic" is a check that always succeeds
    /// and the whole authenticity story is decoration.
    @Test(.enabled(if: LiveUpdateVerifierTests.live))
    func aRequirementNamingAnotherTeamIsRefused() throws {
        guard let claude = installedClaude else {
            Issue.record("no Claude.app at \(CoreConstants.defaultRealClaudePath)")
            return
        }
        let runner = SystemCommandRunner()
        let output = try runner.run(CoreConstants.codesignPath, [
            "--verify", "--strict",
            "-R", "=anchor apple generic and certificate leaf[subject.OU] = \"NOTANTHROPIC\"",
            claude.path
        ])

        #expect(!output.succeeded, "a requirement naming the wrong team was accepted")
    }
}
