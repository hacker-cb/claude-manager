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

    /// Found the way the app finds it, not at a hard-coded path: an install elsewhere is a
    /// perfectly ordinary setup, and failing there would report a broken test rather than a
    /// missing app.
    private var installedClaude: URL? {
        try? RealClaudeLocator().locate().appURL
    }

    @Test(.enabled(if: LiveUpdateVerifierTests.live))
    func theInstalledClaudePassesEverySigningCheck() throws {
        guard let claude = installedClaude else {
            Issue.record("no installed Claude.app to check against")
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
            Issue.record("no installed Claude.app to check against")
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

    /// The check that matters, run for real: take the genuine installed bundle, alter one
    /// sealed resource, and confirm the verifier refuses it.
    ///
    /// Everything else here proves a good bundle passes. This proves a bad one does not —
    /// which is the half that would make the difference if the signature checks were ever
    /// quietly weakened. Copies ~800 MB into the temporary directory and removes it after.
    @Test(.enabled(if: LiveUpdateVerifierTests.live))
    func aTamperedBundleIsRefused() throws {
        guard let claude = installedClaude else {
            Issue.record("no installed Claude.app to check against")
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm-tamper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent(CoreConstants.claudeAppName)
        try FileManager.default.copyItem(at: claude, to: copy)

        // Any sealed resource will do — covered by the signature, unlike a file added
        // outside it. Picked from what is actually there rather than named outright: a
        // renamed resource would otherwise fail this test as "broken" rather than as
        // "the bundle changed".
        let resources = copy.appendingPathComponent("Contents/Resources")
        let candidates = try FileManager.default.contentsOfDirectory(atPath: resources.path)
        guard let name = candidates.sorted().first(where: { !$0.hasPrefix(".") }) else {
            Issue.record("no sealed resource found to tamper with")
            return
        }
        let handle = try FileHandle(forWritingTo: resources.appendingPathComponent(name))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tampered".utf8))
        try handle.close()

        let verifier = UpdateVerifier(runner: SystemCommandRunner())
        #expect(throws: UpdateVerifier.Failure.self) { try verifier.checkSignature(copy) }
    }

    /// The symlink substitution, run against the real signing tools.
    ///
    /// An archive containing `Claude.app` as a link to the installed app makes every check
    /// answer about the genuine bundle: `codesign` and `spctl` follow the link, the version
    /// read through it matches, and the verifier would hand back a "verified" symlink that
    /// the install step then swaps into `/Applications`, destroying what it points at. The
    /// stubbed test proves the guard fires; this proves the tools really would have been
    /// fooled without it.
    @Test(.enabled(if: LiveUpdateVerifierTests.live))
    func aSymlinkToTheInstalledClaudeIsRefused() throws {
        guard let claude = installedClaude else {
            Issue.record("no installed Claude.app to check against")
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Claude-x.zip")
        try Data("stand-in".utf8).write(to: archive)
        let installedVersion = RealClaude(appURL: claude).version() ?? "?"

        // `ditto` is stubbed to plant the link; codesign and spctl are the real ones.
        let runner = RecordingCommandRunner { executable, arguments in
            if executable == CoreConstants.dittoPath, let destination = arguments.last {
                try? FileManager.default.createSymbolicLink(
                    at: URL(fileURLWithPath: destination).appendingPathComponent(CoreConstants.claudeAppName),
                    withDestinationURL: claude
                )
            }
            return CommandOutput(exitCode: 0, standardOutput: "", standardError: "")
        }
        runner.setDelegated([CoreConstants.codesignPath, CoreConstants.spctlPath])

        let download = PreparedDownload(
            version: installedVersion, archiveURL: archive, byteSize: 8
        )
        #expect(throws: UpdateVerifier.Failure.self) {
            try UpdateVerifier(runner: runner).verify(
                download,
                unpackingInto: root.appendingPathComponent("s")
            )
        }
    }
}
