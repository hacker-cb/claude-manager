import Foundation

/// An unpacked Claude bundle that has passed every check, ready to replace the installed one.
public struct VerifiedUpdate: Equatable, Sendable {
    /// `CFBundleShortVersionString` read from the unpacked bundle itself.
    public let version: String
    /// The unpacked `Claude.app`, on the same volume as `/Applications`.
    public let appURL: URL

    public init(version: String, appURL: URL) {
        self.version = version
        self.appURL = appURL
    }
}

/// Unpacks a downloaded archive and proves it is a genuine Claude build before anything is
/// allowed near `/Applications/Claude.app`.
///
/// **This is where authenticity comes from.** The feed hands out a version and a URL over
/// TLS, and that is all the trust the network can give: a digest served beside the download
/// it describes proves only that the bytes arrived intact. What proves the bundle is
/// Anthropic's is its own Apple-issued signature, its notarization ticket, and its team
/// identifier — none of which the release channel can influence, and all of which are
/// checked here, in this order:
///
/// 1. the archive unpacks to exactly one `Claude.app`;
/// 2. `codesign --verify --strict --deep` — the signature covers the bundle and nothing in
///    it has been altered;
/// 3. the same check against a **designated requirement** naming Apple's anchor and team
///    `Q6L2SF6YDW`, which is what makes it Anthropic's build rather than merely *a*
///    validly-signed one;
/// 4. `spctl --assess --type exec` — the ticket Apple issued at notarization;
/// 5. the bundle identifier is Claude's;
/// 6. the version matches what the feed advertised.
///
/// Any failure abandons the unpacked copy. There is no "install anyway".
///
/// **Unpacked with `ditto`, not `unzip`.** Both were measured to leave the signature valid
/// on this archive, but `ditto` is what Apple's own tooling uses for signed bundles: it
/// preserves extended attributes and symlinks, which `unzip` is not obliged to, and a bundle
/// that loses either is one `codesign` refuses for reasons that look nothing like the cause.
public struct UpdateVerifier: Sendable {
    public enum Failure: Error, Equatable {
        /// The archive did not unpack to a single `Claude.app` at its top level.
        case unexpectedArchiveContents(String)
        /// `codesign --verify` refused the bundle: the signature is missing, broken, or does
        /// not cover what is on disk.
        case signatureInvalid(String)
        /// Validly signed, but not by Anthropic. The interesting failure: it is what a
        /// substituted bundle looks like.
        case notAnthropicSigned(String)
        /// Apple has no notarization ticket for this bundle.
        case notNotarized(String)
        /// The bundle identifier is not Claude's.
        case unexpectedBundleIdentifier(String?)
        /// The build inside does not match the release the feed offered. Refused rather than
        /// accepted-with-a-correction: the two disagreeing means one of them is not
        /// describing what was downloaded, and guessing which is not this code's business.
        case versionMismatch(expected: String, found: String?)
    }

    let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    /// Unpack `download` into `stagingDirectory` and check it end to end.
    ///
    /// - Parameter stagingDirectory: emptied first, and must sit on the same volume as
    ///   `/Applications` — the install that follows swaps the bundle in with an atomic
    ///   rename, which only works within one volume.
    public func verify(
        _ download: PreparedDownload,
        unpackingInto stagingDirectory: URL
    ) throws -> VerifiedUpdate {
        CoreLog.update.info("verify: unpacking \(download.version, privacy: .public)")
        let appURL = try unpack(download, into: stagingDirectory)
        do {
            try checkSignature(appURL)
            try checkIsAnthropic(appURL)
            try checkNotarized(appURL)
            let version = try checkIdentity(appURL, expecting: download.version)
            CoreLog.update.info("verify: \(version, privacy: .public) passed every check")
            return VerifiedUpdate(version: version, appURL: appURL)
        } catch {
            // A bundle that failed any check is never left lying next to `/Applications`
            // where a later step — or a person — could mistake it for a good one.
            try? FileManager.default.removeItem(at: stagingDirectory)
            CoreLog.update.error("verify: rejected — \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - Steps

    //
    // The three signing checks are deliberately not `private`: `LiveUpdateVerifierTests`
    // runs them against the real `/Applications/Claude.app`, which is the only way to know
    // the commands themselves are right. Stubs prove the reactions, not the invocations.

    private func unpack(_ download: PreparedDownload, into stagingDirectory: URL) throws -> URL {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: stagingDirectory)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try runner.runChecked(
            CoreConstants.dittoPath, ["-x", "-k", download.archiveURL.path, stagingDirectory.path]
        )
        let entries = (try? fileManager.contentsOfDirectory(atPath: stagingDirectory.path))?
            // `ditto` writes no metadata files of its own, but an archive built elsewhere can
            // carry `__MACOSX` or a stray `.DS_Store`; neither makes the contents unexpected.
            .filter { !$0.hasPrefix(".") && $0 != "__MACOSX" } ?? []
        guard entries == [CoreConstants.claudeAppName] else {
            throw Failure.unexpectedArchiveContents(entries.sorted().joined(separator: ", "))
        }
        return stagingDirectory.appendingPathComponent(CoreConstants.claudeAppName)
    }

    func checkSignature(_ appURL: URL) throws {
        let output = try runner.run(
            CoreConstants.codesignPath,
            ["--verify", "--strict", "--deep", appURL.path]
        )
        guard output.succeeded else {
            throw Failure
                .signatureInvalid(output.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The check that a substituted bundle fails.
    ///
    /// Expressed as a designated requirement rather than by parsing `codesign -dv` output:
    /// the requirement language is evaluated by the same code that validates the signature,
    /// so there is no text to misread and no locale to trip over.
    func checkIsAnthropic(_ appURL: URL) throws {
        let output = try runner.run(
            CoreConstants.codesignPath,
            ["--verify", "--strict", "-R", CoreConstants.anthropicDesignatedRequirement, appURL.path]
        )
        guard output.succeeded else {
            throw Failure
                .notAnthropicSigned(output.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func checkNotarized(_ appURL: URL) throws {
        let output = try runner.run(CoreConstants.spctlPath, ["--assess", "--type", "exec", appURL.path])
        guard output.succeeded else {
            throw Failure.notNotarized(output.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Read the unpacked bundle's own identity and hold it against what was advertised.
    private func checkIdentity(_ appURL: URL, expecting version: String) throws -> String {
        let real = RealClaude(appURL: appURL)
        let bundleID = real.bundleIdentifier()
        guard let bundleID, CoreConstants.realClaudeBundleIDs.contains(bundleID) else {
            throw Failure.unexpectedBundleIdentifier(bundleID)
        }
        guard let found = real.version(), found == version else {
            throw Failure.versionMismatch(expected: version, found: real.version())
        }
        return found
    }
}
