import Foundation
import Testing
@testable import ClaudeManagerCore

struct UpdateDownloaderTests {
    /// Stub downloader: writes canned bytes, or throws, and records what it was asked for.
    private final class StubDownloader: FileDownloader, @unchecked Sendable {
        enum Behaviour {
            case writes(String)
            case interrupted(resumeData: Data?)
            case fails(Error)
        }

        struct Call {
            let url: URL
            let destination: URL
            let resumeData: Data?
        }

        var behaviour: Behaviour
        private(set) var calls: [Call] = []

        init(_ behaviour: Behaviour) {
            self.behaviour = behaviour
        }

        func download(
            from url: URL,
            to destination: URL,
            resumeData: Data?,
            progress: @Sendable @escaping (Int64, Int64?) -> Void
        ) async throws -> Int64 {
            calls.append(Call(url: url, destination: destination, resumeData: resumeData))
            switch behaviour {
            case let .writes(contents):
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data(contents.utf8).write(to: destination)
                progress(Int64(contents.utf8.count), Int64(contents.utf8.count))
                return Int64(contents.utf8.count)
            case let .interrupted(resumeData):
                throw DownloadInterrupted(
                    resumeData: resumeData,
                    underlying: URLError(.networkConnectionLost)
                )
            case let .fails(error):
                throw error
            }
        }
    }

    private func makeCache() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm-downloader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func update(_ version: String) -> AvailableUpdate {
        AvailableUpdate(
            version: version,
            downloadURL: URL(string: "https://downloads.claude.ai/releases/\(version)/Claude.zip")!
        )
    }

    private func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    // MARK: - Fetching

    @Test
    func stagesTheArchiveUnderItsVersion() async throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let stub = StubDownloader(.writes("zip-bytes"))
        let downloader = UpdateDownloader(downloader: stub, cacheDirectory: cache)

        let staged = try await downloader.fetch(update("1.37937.1"))

        #expect(staged.version == "1.37937.1")
        #expect(staged.byteSize == 9)
        #expect(names(in: cache) == ["Claude-1.37937.1.zip"])
        #expect(downloader.prepared() == staged)
    }

    /// A background check runs on a timer; re-fetching 335 MB on every tick to learn nothing
    /// changed would be an expensive no-op.
    @Test
    func doesNotRefetchAVersionAlreadyStaged() async throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let stub = StubDownloader(.writes("zip-bytes"))
        let downloader = UpdateDownloader(downloader: stub, cacheDirectory: cache)

        _ = try await downloader.fetch(update("1.37937.1"))
        _ = try await downloader.fetch(update("1.37937.1"))

        #expect(stub.calls.count == 1)
    }

    /// One build at a time: an archive nobody will install is ~335 MB of dead weight.
    @Test
    func discardsAnOlderStagedBuildWhenANewerOneArrives() async throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let stub = StubDownloader(.writes("old"))
        let downloader = UpdateDownloader(downloader: stub, cacheDirectory: cache)
        _ = try await downloader.fetch(update("1.30096.5"))

        stub.behaviour = .writes("new-bytes")
        let staged = try await downloader.fetch(update("1.37937.1"))

        #expect(names(in: cache) == ["Claude-1.37937.1.zip"])
        #expect(downloader.prepared() == staged)
    }

    // MARK: - Interruption

    /// The resume token is what keeps a slept-through download from costing a third of a
    /// gigabyte twice.
    @Test
    func keepsResumeStateAndUsesItOnTheNextAttempt() async throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let stub = StubDownloader(.interrupted(resumeData: Data("resume-token".utf8)))
        let downloader = UpdateDownloader(downloader: stub, cacheDirectory: cache)

        await #expect(throws: DownloadInterrupted.self) { try await downloader.fetch(update("1.37937.1")) }
        #expect(names(in: cache).contains("Claude-1.37937.1.resume"))
        // Nothing installable is on offer after an interrupted transfer.
        #expect(downloader.prepared() == nil)

        stub.behaviour = .writes("zip-bytes")
        _ = try await downloader.fetch(update("1.37937.1"))

        #expect(stub.calls.last?.resumeData == Data("resume-token".utf8))
        // Consumed on success, so a later attempt does not resume into a finished file.
        #expect(!names(in: cache).contains("Claude-1.37937.1.resume"))
    }

    /// A failure that cannot be resumed must not leave a token behind: the next attempt
    /// would hand `URLSession` state describing a transfer that no longer applies.
    @Test
    func clearsStaleResumeStateWhenAFailureIsNotResumable() async throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let stub = StubDownloader(.interrupted(resumeData: Data("token".utf8)))
        let downloader = UpdateDownloader(downloader: stub, cacheDirectory: cache)
        await #expect(throws: DownloadInterrupted.self) { try await downloader.fetch(update("1.37937.1")) }

        stub.behaviour = .interrupted(resumeData: nil)
        await #expect(throws: DownloadInterrupted.self) { try await downloader.fetch(update("1.37937.1")) }

        #expect(!names(in: cache).contains("Claude-1.37937.1.resume"))
    }

    /// The transport can report success and still leave nothing usable; that is not an
    /// archive to hand to the verifier.
    @Test
    func refusesAnEmptyArchive() async throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let downloader = UpdateDownloader(downloader: StubDownloader(.writes("")), cacheDirectory: cache)

        await #expect(throws: UpdateDownloader.Failure.emptyArchive) {
            try await downloader.fetch(update("1.37937.1"))
        }
        #expect(downloader.prepared() == nil)
    }

    // MARK: - What counts as prepared

    /// The whole point of the `.partial` name: a transfer killed half way leaves bytes on
    /// disk, and those bytes must never look like a build ready to install.
    @Test
    func neverReportsAPartialTransferAsPrepared() throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Data("half".utf8).write(to: cache.appendingPathComponent("Claude-1.37937.1.zip.partial"))
        let downloader = UpdateDownloader(downloader: StubDownloader(.writes("x")), cacheDirectory: cache)

        #expect(downloader.prepared() == nil)
    }

    @Test
    func ignoresFilesItDoesNotOwn() throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Data("x".utf8).write(to: cache.appendingPathComponent("something-else.zip"))
        try Data("x".utf8).write(to: cache.appendingPathComponent("Claude-not-a-version.zip"))
        let downloader = UpdateDownloader(downloader: StubDownloader(.writes("x")), cacheDirectory: cache)

        #expect(downloader.prepared() == nil)
    }

    @Test
    func reportsNothingWhenTheCacheDoesNotExist() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cm-absent-\(UUID().uuidString)")
        let downloader = UpdateDownloader(downloader: StubDownloader(.writes("x")), cacheDirectory: missing)

        #expect(downloader.prepared() == nil)
    }

    @Test
    func discardAllLeavesNothingOfItsOwnBehind() async throws {
        let cache = try makeCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let downloader = UpdateDownloader(
            downloader: StubDownloader(.writes("zip-bytes")), cacheDirectory: cache
        )
        _ = try await downloader.fetch(update("1.37937.1"))
        try Data("x".utf8).write(to: cache.appendingPathComponent("unrelated.txt"))

        downloader.discardAll()

        #expect(downloader.prepared() == nil)
        // Someone else's file in the cache directory is not ours to delete.
        #expect(names(in: cache) == ["unrelated.txt"])
    }
}
