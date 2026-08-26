import Foundation

/// Downloads a URL **to a file**, reporting progress.
///
/// Separate from ``HTTPClient`` — which hands back a `Data` — because a Claude build is
/// ~335 MB: buffering that in memory to write it straight back out is a third of a gigabyte
/// of resident size in a menu-bar app, for no gain. `URLSession`'s download task streams to
/// disk on its own.
///
/// Behind a protocol so ``UpdateDownloader`` is testable without a network: the tests
/// substitute a stub that produces bytes, and the one implementation that really talks to
/// `URLSession` stays thin enough to read in one sitting.
public protocol FileDownloader: Sendable {
    /// Fetch `url` into `destination`, replacing anything already there.
    ///
    /// - Parameters:
    ///   - resumeData: opaque state from a previous interrupted attempt, if any.
    ///   - progress: called as bytes arrive. Never assume a total: a server may answer
    ///     without a length, in which case `totalBytes` is nil.
    /// - Returns: how many bytes landed.
    /// - Throws: ``DownloadInterrupted`` for **any** transport-level failure. Whether it can
    ///   be picked up later is told by its `resumeData`: non-nil means the next attempt can
    ///   continue, nil means it starts over. Other errors — ``DownloadFailure`` and
    ///   filesystem errors — are terminal for this attempt.
    @discardableResult
    func download(
        from url: URL,
        to destination: URL,
        resumeData: Data?,
        progress: @Sendable @escaping (_ received: Int64, _ totalBytes: Int64?) -> Void
    ) async throws -> Int64
}

/// What went wrong that is the download's own fault rather than the transport's.
public enum DownloadFailure: Error, Equatable {
    /// The server answered, but not with a body we asked for. A resumed transfer answers
    /// 206 and a fresh one 200; anything else written to disk would reach the verifier as a
    /// corrupt archive, which is a far more confusing failure than this one.
    case unexpectedStatus(Int)
    /// `URLSession` reported success without handing over a file.
    case noFileProduced
}

/// A transfer that stopped part way and left enough state to continue.
///
/// Carries the resume token rather than logging it away, because the alternative on a
/// laptop that slept mid-download is re-fetching 335 MB — the exact cost that made a failed
/// ShipIt install so expensive.
public struct DownloadInterrupted: Error, Sendable {
    public let resumeData: Data?
    public let underlying: Error

    public init(resumeData: Data?, underlying: Error) {
        self.resumeData = resumeData
        self.underlying = underlying
    }
}

/// The real downloader, backed by `URLSession`.
public struct URLSessionFileDownloader: FileDownloader {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    @discardableResult
    public func download(
        from url: URL,
        to destination: URL,
        resumeData: Data?,
        progress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws -> Int64 {
        let (temporaryURL, response) = try await transfer(
            url: url,
            resumeData: resumeData,
            progress: progress
        )
        // A resumed transfer answers 206; a fresh one 200. Anything else is not the body we
        // asked for — an error page written to disk would otherwise reach the verifier as a
        // corrupt archive, which is a far more confusing failure than this one.
        if let http = response as? HTTPURLResponse, ![200, 206].contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DownloadFailure.unexpectedStatus(http.statusCode)
        }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // `moveItem` rather than `replaceItemAt`: the download lands in the system temporary
        // directory, which is not necessarily the same volume as the destination, and
        // `replaceItemAt` is only atomic within one.
        try fileManager.moveItem(at: temporaryURL, to: destination)
        // Deliberately not `try?`: a failure to stat a file that was just written is a real
        // error, and reporting it as `0` would make the caller destroy a good download and
        // report it as empty — a confusing lie about what happened.
        let size = try fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int64
        guard let size else { throw DownloadFailure.noFileProduced }
        return size
    }

    /// Bridge `URLSessionDownloadTask` — whose progress and completion arrive through KVO
    /// and a callback — into one `async` call.
    private func transfer(
        url: URL,
        resumeData: Data?,
        progress: @Sendable @escaping (Int64, Int64?) -> Void
    ) async throws -> (URL, URLResponse?) {
        let observer = ProgressRelay(report: progress)
        return try await withCheckedThrowingContinuation { continuation in
            let handler: @Sendable (URL?, URLResponse?, Error?) -> Void = { location, response, error in
                observer.stop()
                if let error {
                    // `NSURLSessionDownloadTaskResumeData` is how URLSession hands back the
                    // "you can continue from here" token; without it the next attempt starts
                    // from zero, which is allowed but expensive.
                    let token = (error as NSError)
                        .userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                    continuation.resume(throwing: DownloadInterrupted(resumeData: token, underlying: error))
                    return
                }
                guard let location else {
                    continuation.resume(throwing: DownloadFailure.noFileProduced)
                    return
                }
                // The completion handler's file is deleted the moment this returns, so it is
                // moved aside *here*, synchronously, and handed on as a URL that will still
                // exist when the caller resumes.
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("claude-manager-download-\(UUID().uuidString)")
                do {
                    try FileManager.default.moveItem(at: location, to: staging)
                    continuation.resume(returning: (staging, response))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            let task = resumeData.map { session.downloadTask(withResumeData: $0, completionHandler: handler) }
                ?? session.downloadTask(with: url, completionHandler: handler)
            observer.observe(task)
            task.resume()
        }
    }
}

/// Relays a download task's byte counts to a callback, and stops cleanly when it finishes.
///
/// A tiny class rather than a closure because KVO needs an object to hold the observation,
/// and it has to be released deterministically — an observation outliving its task is a
/// crash on some OS versions, not merely a leak.
private final class ProgressRelay: NSObject, @unchecked Sendable {
    private let report: @Sendable (Int64, Int64?) -> Void
    private var observation: NSKeyValueObservation?

    init(report: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.report = report
    }

    func observe(_ task: URLSessionDownloadTask) {
        observation = task.progress.observe(\.completedUnitCount) { [report] progress, _ in
            // `totalUnitCount` is -1 until the response arrives, and stays there when the
            // server sends no length. Reported as nil rather than as a bogus total.
            let total = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
            report(progress.completedUnitCount, total)
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }
}
