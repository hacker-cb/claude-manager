import Foundation

/// A downloaded Claude archive sitting in the cache, ready to be verified and installed.
public struct PreparedDownload: Equatable, Sendable {
    public let version: String
    /// The `.zip` on disk, with `Claude.app` at its top level.
    public let archiveURL: URL
    public let byteSize: Int64

    public init(version: String, archiveURL: URL, byteSize: Int64) {
        self.version = version
        self.archiveURL = archiveURL
        self.byteSize = byteSize
    }
}

/// Fetches a Claude build into a cache directory and keeps **exactly one** of them.
///
/// Holding one build is a deliberate policy, not a simplification. The archive is ~335 MB;
/// keeping a history of them would quietly cost gigabytes on a laptop, and a build older
/// than the newest is of no use to anyone — this app installs the latest on request and
/// never rolls back. So when a newer release appears, whatever was staged is discarded and
/// the new one fetched from scratch.
///
/// **Not single-flight.** Overlapping `fetch` calls are the caller's to prevent; the cache
/// self-corrects (each publish sweeps again, and `prepared()` reports the newest) but two
/// concurrent transfers still waste a download. The orchestrator drives one at a time.
///
/// An interrupted transfer is resumable: a laptop that sleeps mid-download picks up where it
/// left off rather than re-fetching a third of a gigabyte. That cost is the whole reason
/// this is worth doing carefully — a destroyed ShipIt install used to cost exactly that, and
/// it was what made the old update path so expensive to get wrong.
/// `Sendable`, unlike the core's other filesystem services. Those (`StagedUpdateProbe`,
/// `ManagedConfigWriter`) are entirely synchronous, so they never leave the actor that owns
/// them and holding a `FileManager` costs nothing. `fetch` is `async` and runs for minutes:
/// a `@MainActor` owner storing one of these would be sending a non-`Sendable` value across
/// an isolation boundary, which Swift 6 rejects outright — so this type uses
/// `FileManager.default` (documented thread-safe for these operations) rather than storing
/// an injected one.
public struct UpdateDownloader: Sendable {
    public enum Failure: Error, Equatable {
        /// The transfer completed but the file on disk is empty, so there is nothing to
        /// verify. Distinct from a transport error: the network said it succeeded.
        case emptyArchive
    }

    let downloader: FileDownloader
    let cacheDirectory: URL

    /// `FileManager.default`, reached through a computed property so the call sites read the
    /// same as the rest of the core.
    private var fileManager: FileManager {
        .default
    }

    public init(
        downloader: FileDownloader = URLSessionFileDownloader(),
        cacheDirectory: URL
    ) {
        self.downloader = downloader
        self.cacheDirectory = cacheDirectory
    }

    /// The archive already staged, if one is.
    ///
    /// Only a **completed** download is ever reported: a transfer in flight lives under a
    /// `.partial` name and is renamed into place as its last step, so a half-written archive
    /// can never be mistaken for one ready to install.
    public func prepared() -> PreparedDownload? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: cacheDirectory.path)
        else { return nil }
        var newest: PreparedDownload?
        for name in names where name.hasPrefix(Self.archivePrefix) && name.hasSuffix(".zip") {
            let version = String(name.dropFirst(Self.archivePrefix.count).dropLast(4))
            guard VersionOrder.isComparable(version) else { continue }
            let url = cacheDirectory.appendingPathComponent(name)
            let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64
            guard let size, size > 0 else { continue }
            // Ordered by version, never by filename: sorted lexicographically `1.10` comes
            // before `1.2`, so the first match can be the *older* build. The one-at-a-time
            // policy should keep this to a single candidate, but a crash between the discard
            // and the rename can leave two, and picking the older one to install is exactly
            // the wrong recovery.
            if let current = newest, !VersionOrder.isNewer(version, than: current.version) { continue }
            newest = PreparedDownload(version: version, archiveURL: url, byteSize: size)
        }
        return newest
    }

    /// Fetch `update` into the cache, resuming an earlier attempt at the same version when
    /// one was interrupted.
    ///
    /// Returns the already-staged archive untouched when it is the requested version — a
    /// background check runs on a timer, and re-fetching 335 MB on each tick would be an
    /// expensive way to learn nothing changed.
    @discardableResult
    public func fetch(
        _ update: AvailableUpdate,
        progress: @Sendable @escaping (_ received: Int64, _ total: Int64?) -> Void = { _, _ in }
    ) async throws -> PreparedDownload {
        if let staged = prepared(), staged.version == update.version {
            CoreLog.update.info("download: \(update.version, privacy: .public) already staged")
            return staged
        }
        // Anything staged now is a build nobody will install; drop it before fetching so the
        // cache never holds two archives at once.
        discardStaged(except: update.version)

        let destination = archiveURL(for: update.version)
        let partial = destination.appendingPathExtension("partial")
        let resume = resumeURL(for: update.version)
        let resumeData = fileManager.contents(atPath: resume.path)
        CoreLog.update.info(
            """
            download: fetching \(update.version, privacy: .public) \
            from \(update.downloadURL.logDescription, privacy: .public)\
            \(resumeData == nil ? "" : " (resuming)", privacy: .public)
            """
        )
        var byteSize: Int64
        do {
            byteSize = try await downloader.download(
                from: update.downloadURL, to: partial, resumeData: resumeData, progress: progress
            )
        } catch let interrupted as DownloadInterrupted {
            // Cancellation arrives here too, as `URLError.cancelled` with a resume token
            // attached — deliberately not special-cased, because the handling is identical
            // and the one thing that must not happen is throwing the token away. (An earlier
            // `catch is CancellationError` branch was dead code that would have done exactly
            // that the day an implementation started throwing one.)
            //
            // Keep the token so the next attempt continues; without it the retry starts from
            // zero. A `nil` token means the failure was not resumable, and any stale token
            // from a previous attempt has to go with it.
            if let token = interrupted.resumeData {
                try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try? token.write(to: resume, options: .atomic)
                CoreLog.update.error(
                    """
                    download: interrupted, \(token.count, privacy: .public) bytes of resume state kept \
                    — \(interrupted.underlying.localizedDescription, privacy: .public)
                    """
                )
            } else {
                try? fileManager.removeItem(at: resume)
                CoreLog.update.error(
                    """
                    download: interrupted with no resume state \
                    — \(interrupted.underlying.localizedDescription, privacy: .public)
                    """
                )
            }
            throw interrupted
        } catch where resumeData != nil {
            // A resumed transfer that failed outright — the classic case is the server
            // rejecting the byte range with 416 after the archive behind it was replaced.
            // Keeping the token would wedge this version forever: every later attempt would
            // replay the same bad range and fail identically. Drop it and start over once,
            // here, rather than leaving the user to hope a background tick recovers.
            try? fileManager.removeItem(at: resume)
            try? fileManager.removeItem(at: partial)
            CoreLog.update.error(
                """
                download: resumed attempt failed \
                (\(error.localizedDescription, privacy: .public)) — refetching from scratch
                """
            )
            byteSize = try await downloader.download(
                from: update.downloadURL, to: partial, resumeData: nil, progress: progress
            )
        } catch {
            CoreLog.update.error("download: failed — \(error.localizedDescription, privacy: .public)")
            throw error
        }
        try? fileManager.removeItem(at: resume)
        guard byteSize > 0 else {
            try? fileManager.removeItem(at: partial)
            CoreLog.update.error("download: archive is empty")
            throw Failure.emptyArchive
        }
        // The rename is what publishes it: until this line the archive is `.partial` and
        // `prepared()` will not report it, so a crash mid-transfer cannot leave a truncated
        // file looking installable.
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: partial, to: destination)
        // Swept again *after* publishing, not only before: this type is not single-flight,
        // and two overlapping fetches can each pass the first discard before either renames.
        // The second sweep leaves one archive whichever way they interleave; `prepared()`
        // picking the newest covers the instant in between.
        discardStaged(except: update.version)
        CoreLog.update.info(
            """
            download: staged \(update.version, privacy: .public), \
            \(byteSize, privacy: .public) bytes
            """
        )
        return PreparedDownload(version: update.version, archiveURL: destination, byteSize: byteSize)
    }

    /// Drop every staged archive, and every trace of a transfer in flight.
    ///
    /// Used when the feature is switched off, and after an install has consumed one: an
    /// archive matching what is now installed is dead weight.
    public func discardAll() {
        discardStaged(except: nil)
    }

    /// Remove staged archives, partial transfers and resume tokens other than `version`'s.
    private func discardStaged(except version: String?) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: cacheDirectory.path) else { return }
        // The exact three names this type gives one version, never a prefix of them: the
        // prefix `Claude-1.2` also matches `Claude-1.20.0.zip`, so keeping "this version's
        // files" by prefix would silently keep a second build and break the one-at-a-time
        // policy the whole cache rests on.
        let keep = version.map(Self.ownedNames(for:)) ?? []
        for name in names where name.hasPrefix(Self.archivePrefix) {
            if keep.contains(name) { continue }
            let url = cacheDirectory.appendingPathComponent(name)
            do {
                try fileManager.removeItem(at: url)
                CoreLog.update.info("download: discarded \(name, privacy: .public)")
            } catch {
                // Not fatal: a leftover archive costs disk, not correctness, and the next
                // fetch overwrites its own destination anyway.
                CoreLog.update.error(
                    """
                    download: could not discard \(name, privacy: .public) \
                    — \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
    }

    /// Every file this type may create for one version.
    static func ownedNames(for version: String) -> Set<String> {
        let stem = "\(archivePrefix)\(version)"
        return ["\(stem).zip", "\(stem).zip.partial", "\(stem).resume"]
    }

    private func archiveURL(for version: String) -> URL {
        cacheDirectory.appendingPathComponent("\(Self.archivePrefix)\(version).zip")
    }

    private func resumeURL(for version: String) -> URL {
        cacheDirectory.appendingPathComponent("\(Self.archivePrefix)\(version).resume")
    }

    /// Shared prefix for everything this type owns in the cache directory, so a sweep can
    /// tell its own files from anything else that may live there.
    static let archivePrefix = "Claude-"
}
