import Foundation

/// Ties the four update steps together: ask, fetch, prove, hand over.
///
/// Deliberately does **not** install. The swap closes every one of the user's profiles, and
/// that belongs to `ProfileStore` — which owns the instances — and to a deliberate press,
/// not to a background task that happens to have finished a download. So this prepares, and
/// stops.
///
/// Preparing is safe to run unattended precisely because it changes nothing the user can
/// see: bytes land in a cache directory, and the bundle unpacked from them sits beside the
/// installed app until someone asks for it.
public struct ClaudeUpdateService: Sendable {
    let feed: UpdateFeed
    let downloader: UpdateDownloader
    let verifier: UpdateVerifier
    let stagingDirectory: URL

    /// - Parameter stagingDirectory: where a verified bundle is unpacked. Must share a volume
    ///   with `/Applications`, since the install swaps it in by rename.
    public init(
        feed: UpdateFeed,
        downloader: UpdateDownloader,
        verifier: UpdateVerifier,
        stagingDirectory: URL
    ) {
        self.feed = feed
        self.downloader = downloader
        self.verifier = verifier
        self.stagingDirectory = stagingDirectory
    }

    /// The latest release, when it is newer than what is installed; `nil` when it is not.
    ///
    /// Throwing and `nil` mean different things and are kept apart: "there is no update" is
    /// an answer, "I could not ask" is not, and collapsing them is how a broken feed comes to
    /// look like a machine that is up to date.
    public func checkForUpdate(installedVersion: String?) async throws -> AvailableUpdate? {
        let latest = try await feed.latest()
        guard latest.isUpgrade(over: installedVersion) else {
            CoreLog.update.info(
                """
                check: \(latest.version, privacy: .public) is not newer than \
                \(installedVersion ?? "unknown", privacy: .public)
                """
            )
            return nil
        }
        return latest
    }

    /// Download `update` and prove it, leaving a bundle ready to install.
    ///
    /// The download is resumable and the archive is kept, so calling this again after an
    /// interruption continues rather than starting over. Verification is not cached: it is
    /// seconds of work against an archive that is the whole basis for replacing the user's
    /// app, and skipping it on a second pass would mean trusting a file that has been sitting
    /// on disk since.
    public func prepare(
        _ update: AvailableUpdate,
        progress: @Sendable @escaping (_ received: Int64, _ total: Int64?) -> Void = { _, _ in }
    ) async throws -> VerifiedUpdate {
        let downloaded = try await downloader.fetch(update, progress: progress)
        return try verifier.verify(downloaded, unpackingInto: stagingDirectory)
    }

    /// Forget everything staged — the archive, any partial transfer, and the unpacked bundle.
    ///
    /// Called when the feature is switched off and after an install has consumed one: an
    /// archive matching what is now installed is several hundred megabytes of nothing.
    public func discardEverything() {
        downloader.discardAll()
        try? FileManager.default.removeItem(at: stagingDirectory)
        CoreLog.update.info("discarded staged update material")
    }
}
