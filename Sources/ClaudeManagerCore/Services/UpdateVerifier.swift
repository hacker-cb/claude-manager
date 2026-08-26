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
        /// What unpacked is not a real directory — a symlink, or a plain file wearing the
        /// name. Every check below this one follows the link and answers about whatever it
        /// points at, so this has to be refused before any of them run.
        case bundleIsNotADirectory(String)
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
        do {
            // `unpack` is inside the cleanup, not before it: it is the step most likely to
            // leave half an archive on disk, and "any failure abandons the unpacked copy" is
            // not a guarantee that can have an exception for the messiest case.
            let appURL = try unpack(download, into: stagingDirectory)
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
            // Two names, not "anything hidden". `ditto` writes no metadata of its own, but an
            // archive built elsewhere can carry these two; ignoring every dotted name instead
            // would let an archive smuggle a `.payload/` of any size past a guard whose whole
            // claim is "this unpacked to exactly one Claude.app".
            .filter { !CoreConstants.archiveMetadataNames.contains($0) } ?? []
        guard entries == [CoreConstants.claudeAppName] else {
            throw Failure.unexpectedArchiveContents(entries.sorted().joined(separator: ", "))
        }
        let appURL = stagingDirectory.appendingPathComponent(CoreConstants.claudeAppName)
        try requireRealDirectory(appURL, within: stagingDirectory)
        return appURL
    }

    /// Refuse anything that is not genuinely a directory sitting inside the staging area.
    ///
    /// **This is load-bearing, and it is not obvious.** An archive is free to contain
    /// `Claude.app` as a *symlink*. Every check that follows resolves it: `codesign` and
    /// `spctl` would assess whatever it points at — the real, installed, perfectly genuine
    /// Claude — and the version read through it would match too. The verifier would then
    /// hand back a "verified bundle" that is a symlink, and the install step would swap that
    /// link into `/Applications`, destroying the app it points at. Every check passes and
    /// the outcome is catastrophic, which is exactly the shape of failure worth being
    /// paranoid about.
    ///
    /// `attributesOfItem` is used rather than `fileExists(isDirectory:)` because it reports
    /// the link itself instead of following it, and the resolved path is required to stay
    /// inside the staging directory so a link cannot point out of it either.
    private func requireRealDirectory(_ appURL: URL, within stagingDirectory: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: appURL.path)
        guard (attributes?[.type] as? FileAttributeType) == .typeDirectory else {
            let kind = (attributes?[.type] as? FileAttributeType)?.rawValue ?? "unreadable"
            throw Failure.bundleIsNotADirectory(kind)
        }
        let resolved = URL(fileURLWithPath: appURL.path).resolvingSymlinksInPath().path
        let stagingResolved = stagingDirectory.resolvingSymlinksInPath().path
        guard resolved == stagingResolved + "/" + CoreConstants.claudeAppName else {
            throw Failure.bundleIsNotADirectory("resolves outside the staging directory")
        }
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
        // Read once and reused for both the comparison and the error: reading twice lets the
        // value reported diverge from the value actually checked.
        let found = real.version()
        guard let found, found == version else {
            throw Failure.versionMismatch(expected: version, found: found)
        }
        return found
    }
}
