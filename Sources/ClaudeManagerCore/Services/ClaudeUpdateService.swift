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
        do {
            return try verifier.verify(downloaded, unpackingInto: stagingDirectory)
        } catch {
            // The archive goes with the failure. `fetch` returns a cached archive of the same
            // version without re-downloading, so keeping a corrupt one means every retry
            // repeats the identical failure — a "try again" button that cannot ever succeed,
            // until a different release happens to come along.
            CoreLog.update.error("prepare: discarding the archive that failed verification")
            downloader.discardAll()
            throw error
        }
    }

    /// Re-establish a build prepared before the app was last quit.
    ///
    /// The state lives in memory, so without this a build downloaded and verified at 10:00
    /// is invisible after a relaunch at 10:05 — and the schedule would not look again for
    /// hours, with several hundred verified megabytes sitting on disk.
    ///
    /// Verified again rather than trusted: the archive has been on disk across a quit, and
    /// re-proving it costs seconds against the one thing that licenses replacing the user's
    /// app. `nil` when nothing is staged, or when what is staged no longer passes.
    public func restorePrepared(newerThan installedVersion: String?) -> VerifiedUpdate? {
        guard let staged = downloader.prepared() else { return nil }
        guard AvailableUpdate.isUpgrade(staged.version, over: installedVersion) else {
            CoreLog.update.info(
                "restore: staged \(staged.version, privacy: .public) is not newer than what is installed"
            )
            discardEverything()
            return nil
        }
        do {
            let verified = try verifier.verify(staged, unpackingInto: stagingDirectory)
            CoreLog.update.info("restore: \(verified.version, privacy: .public) is ready")
            return verified
        } catch {
            CoreLog.update.error(
                "restore: staged archive no longer verifies — \(String(describing: error), privacy: .public)"
            )
            discardEverything()
            return nil
        }
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
