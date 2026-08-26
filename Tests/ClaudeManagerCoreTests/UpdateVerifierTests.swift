import Foundation
import Testing
@testable import ClaudeManagerCore

/// Drives ``UpdateVerifier`` against a fake unpack step, so every refusal path is reachable
/// without a 335 MB archive or a real signature.
///
/// The tool calls are stubbed, but what they are asked is not: several tests assert the exact
/// arguments, because the difference between `codesign --verify` and `codesign --verify -R
/// <requirement>` is the difference between "validly signed" and "signed by Anthropic", and a
/// silent regression there is precisely the one worth catching.
struct UpdateVerifierTests {
    private struct Fake {
        let root: URL
        let staging: URL
        let archive: PreparedDownload
    }

    /// Builds a runner whose `ditto` writes a plausible bundle rather than unpacking, and
    /// whose signing tools answer as told.
    private func makeRunner(
        version: String? = "1.37937.1",
        bundleID: String? = "com.anthropic.claudefordesktop",
        contents: [String]? = nil,
        codesignVerify: Int32 = 0,
        requirement: Int32 = 0,
        spctl: Int32 = 0
    ) -> RecordingCommandRunner {
        RecordingCommandRunner { executable, arguments in
            switch executable {
            case CoreConstants.dittoPath:
                guard let destination = arguments.last else { break }
                let root = URL(fileURLWithPath: destination)
                if let contents {
                    for name in contents {
                        try? FileManager.default.createDirectory(
                            at: root.appendingPathComponent(name), withIntermediateDirectories: true
                        )
                    }
                } else {
                    writeBundle(
                        at: root.appendingPathComponent("Claude.app"),
                        version: version,
                        bundleID: bundleID
                    )
                }
            case CoreConstants.codesignPath:
                let isRequirementCheck = arguments.contains("-R")
                let code = isRequirementCheck ? requirement : codesignVerify
                return CommandOutput(
                    exitCode: code,
                    standardOutput: "",
                    standardError: code == 0 ? "" : "refused"
                )
            case CoreConstants.spctlPath:
                return CommandOutput(
                    exitCode: spctl,
                    standardOutput: "",
                    standardError: spctl == 0 ? "" : "rejected"
                )
            default:
                break
            }
            return CommandOutput(exitCode: 0, standardOutput: "", standardError: "")
        }
    }

    private func writeBundle(at appURL: URL, version: String?, bundleID: String?) {
        let contents = appURL.appendingPathComponent("Contents")
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = [:]
        if let version { plist["CFBundleShortVersionString"] = version }
        if let bundleID { plist["CFBundleIdentifier"] = bundleID }
        let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try? data?.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func makeFake(version: String = "1.37937.1") throws -> Fake {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("Claude-\(version).zip")
        try Data("not-really-a-zip".utf8).write(to: archiveURL)
        return Fake(
            root: root,
            staging: root.appendingPathComponent("staging"),
            archive: PreparedDownload(version: version, archiveURL: archiveURL, byteSize: 16)
        )
    }

    // MARK: - The happy path

    @Test
    func acceptsAGenuineBundleAndReportsItsOwnVersion() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let runner = makeRunner()

        let verified = try UpdateVerifier(runner: runner).verify(fake.archive, unpackingInto: fake.staging)

        #expect(verified.version == "1.37937.1")
        #expect(verified.appURL.lastPathComponent == "Claude.app")
        #expect(FileManager.default.fileExists(atPath: verified.appURL.path))
    }

    /// The team check is the one a substituted bundle fails, so it must actually be asked —
    /// and asked as a requirement, not as a second plain verify.
    @Test
    func asksCodesignToProveTheBundleIsAnthropics() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let runner = makeRunner()

        _ = try UpdateVerifier(runner: runner).verify(fake.archive, unpackingInto: fake.staging)

        let requirementCalls = runner.invocations(of: CoreConstants.codesignPath)
            .filter { $0.arguments.contains("-R") }
        #expect(requirementCalls.count == 1)
        let requirement = requirementCalls.first?.arguments.first { $0.contains("certificate leaf") }
        #expect(requirement?.contains("Q6L2SF6YDW") == true)
        #expect(requirement?.contains("anchor apple generic") == true)
        // The marker OIDs are what pin it to Developer ID specifically; without them the
        // requirement admits any Apple-anchored certificate whose OU happens to match.
        #expect(requirement?.contains("1.2.840.113635.100.6.2.6") == true)
        #expect(requirement?.contains("1.2.840.113635.100.6.1.13") == true)
        // No stray newline or continuation: this string is handed to `codesign` verbatim.
        #expect(requirement?.contains("\n") == false)
        // Same scope as the plain verify, so the two cannot drift apart.
        #expect(requirementCalls.first?.arguments.contains("--deep") == true)
    }

    @Test
    func unpacksWithDittoRatherThanUnzip() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let runner = makeRunner()

        _ = try UpdateVerifier(runner: runner).verify(fake.archive, unpackingInto: fake.staging)

        let ditto = runner.invocations(of: CoreConstants.dittoPath).first
        #expect(ditto?.arguments.prefix(2) == ["-x", "-k"])
    }

    // MARK: - Refusals

    @Test
    func refusesABundleWhoseSignatureDoesNotVerify() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let verifier = UpdateVerifier(runner: makeRunner(codesignVerify: 1))

        #expect(throws: UpdateVerifier.Failure.signatureInvalid("refused")) {
            try verifier.verify(fake.archive, unpackingInto: fake.staging)
        }
    }

    /// Validly signed by *somebody* is not good enough, and this is the case that matters:
    /// it is what a substituted bundle looks like.
    @Test
    func refusesAValidlySignedBundleThatIsNotAnthropics() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let verifier = UpdateVerifier(runner: makeRunner(requirement: 1))

        #expect(throws: UpdateVerifier.Failure.notAnthropicSigned("refused")) {
            try verifier.verify(fake.archive, unpackingInto: fake.staging)
        }
    }

    @Test
    func refusesABundleWithoutANotarizationTicket() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let verifier = UpdateVerifier(runner: makeRunner(spctl: 1))

        #expect(throws: UpdateVerifier.Failure.notNotarized("rejected")) {
            try verifier.verify(fake.archive, unpackingInto: fake.staging)
        }
    }

    @Test
    func refusesABundleThatIsNotClaude() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let verifier = UpdateVerifier(runner: makeRunner(bundleID: "com.example.something"))

        #expect(throws: UpdateVerifier.Failure.unexpectedBundleIdentifier("com.example.something")) {
            try verifier.verify(fake.archive, unpackingInto: fake.staging)
        }
    }

    /// The feed said one thing and the bundle says another; which one is lying is not this
    /// code's guess to make.
    @Test
    func refusesABuildThatIsNotTheAdvertisedVersion() throws {
        let fake = try makeFake(version: "1.37937.1")
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let verifier = UpdateVerifier(runner: makeRunner(version: "1.30096.5"))

        #expect(throws: UpdateVerifier.Failure.versionMismatch(expected: "1.37937.1", found: "1.30096.5")) {
            try verifier.verify(fake.archive, unpackingInto: fake.staging)
        }
    }

    @Test
    func refusesABundleWithNoReadableVersion() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let verifier = UpdateVerifier(runner: makeRunner(version: nil))

        #expect(throws: UpdateVerifier.Failure.versionMismatch(expected: "1.37937.1", found: nil)) {
            try verifier.verify(fake.archive, unpackingInto: fake.staging)
        }
    }

    /// Pinned to the structural failure, not to "throws something": with a loose assertion
    /// this test would still pass if the guard let two bundles through and the *signature*
    /// check happened to refuse them — which is the regression it exists to catch.
    @Test(arguments: [
        (["Claude.app", "Extra.app"], "Claude.app, Extra.app"), // more than one bundle
        (["Something.app"], "Something.app"), // wrong name
        ([] as [String], "") // nothing at all
    ])
    func refusesAnArchiveThatIsNotASingleClaudeApp(_ contents: [String], _ reported: String) throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let verifier = UpdateVerifier(runner: makeRunner(contents: contents))

        #expect(throws: UpdateVerifier.Failure.unexpectedArchiveContents(reported)) {
            try verifier.verify(fake.archive, unpackingInto: fake.staging)
        }
    }

    /// An archive may not hide anything behind a dotted name: the guard's claim is that it
    /// unpacked to exactly one bundle, and `.payload/` of any size would make that false.
    @Test
    func refusesAnArchiveHidingContentBehindADottedName() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let verifier = UpdateVerifier(runner: makeRunner(contents: ["Claude.app", ".payload"]))

        #expect(throws: UpdateVerifier.Failure.unexpectedArchiveContents(".payload, Claude.app")) {
            try verifier.verify(fake.archive, unpackingInto: fake.staging)
        }
    }

    /// `ditto` failing outright — a truncated or corrupt archive — is a refusal like any
    /// other, and one no test covered.
    @Test
    func refusesAnArchiveDittoCannotUnpack() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let runner = RecordingCommandRunner { executable, _ in
            executable == CoreConstants.dittoPath
                ? CommandOutput(exitCode: 1, standardOutput: "", standardError: "corrupt archive")
                : CommandOutput(exitCode: 0, standardOutput: "", standardError: "")
        }

        #expect(throws: (any Error).self) {
            try UpdateVerifier(runner: runner).verify(fake.archive, unpackingInto: fake.staging)
        }
        #expect(!FileManager.default.fileExists(atPath: fake.staging.path))
    }

    /// The flags carry the meaning: `--strict` and `--deep` on the verify, `--type exec` on
    /// the assessment. A regression that dropped one would pass every other test here.
    @Test
    func asksTheSigningToolsWithTheFlagsThatMatter() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let runner = makeRunner()

        _ = try UpdateVerifier(runner: runner).verify(fake.archive, unpackingInto: fake.staging)

        let verify = runner.invocations(of: CoreConstants.codesignPath)
            .first { !$0.arguments.contains("-R") }
        #expect(verify?.arguments.contains("--strict") == true)
        #expect(verify?.arguments.contains("--deep") == true)
        let assess = runner.invocations(of: CoreConstants.spctlPath).first
        #expect(assess?.arguments == [
            "--assess",
            "--type",
            "exec",
            fake.staging
                .appendingPathComponent("Claude.app").path
        ])
    }

    /// Zip files made on macOS often carry these; they say nothing about whether the archive
    /// holds what it should.
    @Test
    func toleratesArchiveMetadataAlongsideTheBundle() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let runner = RecordingCommandRunner { executable, arguments in
            if executable == CoreConstants.dittoPath, let destination = arguments.last {
                let root = URL(fileURLWithPath: destination)
                writeBundle(
                    at: root.appendingPathComponent("Claude.app"),
                    version: "1.37937.1",
                    bundleID: "com.anthropic.claudefordesktop"
                )
                try? FileManager.default.createDirectory(
                    at: root.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true
                )
                try? Data().write(to: root.appendingPathComponent(".DS_Store"))
            }
            return CommandOutput(exitCode: 0, standardOutput: "", standardError: "")
        }

        let verified = try UpdateVerifier(runner: runner).verify(fake.archive, unpackingInto: fake.staging)
        #expect(verified.version == "1.37937.1")
    }

    /// The attack this whole check exists for.
    ///
    /// An archive may contain `Claude.app` as a **symlink**. Everything downstream resolves
    /// it: `codesign` and `spctl` would assess whatever it points at — a real, installed,
    /// genuinely signed Claude — and the version read through it matches too. Every check
    /// passes, the verifier hands back a "verified bundle" that is a link, and the install
    /// step swaps that link into `/Applications`, destroying the app it points at.
    ///
    /// Stubbed here rather than pointed at the real Claude, so it runs everywhere; the live
    /// suite covers the genuine-signature half.
    @Test
    func refusesABundleThatIsASymlinkToSomewhereElse() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let target = fake.root.appendingPathComponent("Elsewhere.app")
        writeBundle(at: target, version: "1.37937.1", bundleID: "com.anthropic.claudefordesktop")
        let runner = RecordingCommandRunner { executable, arguments in
            if executable == CoreConstants.dittoPath, let destination = arguments.last {
                try? FileManager.default.createSymbolicLink(
                    at: URL(fileURLWithPath: destination).appendingPathComponent("Claude.app"),
                    withDestinationURL: target
                )
            }
            return CommandOutput(exitCode: 0, standardOutput: "", standardError: "")
        }

        #expect(throws: UpdateVerifier.Failure.bundleIsNotADirectory("NSFileTypeSymbolicLink")) {
            try UpdateVerifier(runner: runner).verify(fake.archive, unpackingInto: fake.staging)
        }
        // Refused before anything follows the link — the tools are never even asked.
        #expect(runner.invocations(of: CoreConstants.codesignPath).isEmpty)
    }

    /// The same trick with a plain file: `Claude.app` that is not a bundle at all.
    @Test
    func refusesABundleThatIsNotADirectory() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let runner = RecordingCommandRunner { executable, arguments in
            if executable == CoreConstants.dittoPath, let destination = arguments.last {
                try? Data("not a bundle".utf8).write(
                    to: URL(fileURLWithPath: destination).appendingPathComponent("Claude.app")
                )
            }
            return CommandOutput(exitCode: 0, standardOutput: "", standardError: "")
        }

        #expect(throws: UpdateVerifier.Failure.bundleIsNotADirectory("NSFileTypeRegular")) {
            try UpdateVerifier(runner: runner).verify(fake.archive, unpackingInto: fake.staging)
        }
    }

    // MARK: - After a refusal

    /// A rejected bundle sitting next to `/Applications` is one a later step — or a person —
    /// could mistake for a good one.
    @Test
    func leavesNothingBehindWhenItRefuses() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let verifier = UpdateVerifier(runner: makeRunner(requirement: 1))

        #expect(throws: UpdateVerifier.Failure.notAnthropicSigned("refused")) {
            try verifier.verify(fake.archive, unpackingInto: fake.staging)
        }
        #expect(!FileManager.default.fileExists(atPath: fake.staging.path))
    }

    /// The checks run in order, and the cheap structural one comes first: a bundle that is
    /// not there cannot be signed by anybody.
    @Test
    func doesNotRunTheSigningToolsOnAnArchiveItAlreadyRejected() throws {
        let fake = try makeFake()
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let runner = makeRunner(contents: ["Something.app"])

        #expect(throws: UpdateVerifier.Failure.unexpectedArchiveContents("Something.app")) {
            try UpdateVerifier(runner: runner).verify(fake.archive, unpackingInto: fake.staging)
        }
        #expect(runner.invocations(of: CoreConstants.codesignPath).isEmpty)
        #expect(runner.invocations(of: CoreConstants.spctlPath).isEmpty)
        // The messiest failure is also the one most likely to leave half an archive behind,
        // so the "nothing survives a refusal" guarantee is asserted here too and not only on
        // the paths that get as far as the signing tools.
        #expect(!FileManager.default.fileExists(atPath: fake.staging.path))
    }
}
