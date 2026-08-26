import Foundation
import Testing
@testable import ClaudeManagerCore

/// The four steps wired together: ask, fetch, prove, stop short of installing.
struct ClaudeUpdateServiceTests {
    let fm = FileManager.default

    private typealias Handler = @Sendable (URL, [String: String], TimeInterval) async throws -> HTTPResponse

    private struct MockHTTP: HTTPClient {
        let handler: Handler
        func get(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResponse {
            try await handler(url, headers, timeout)
        }
    }

    private final class StubDownloader: FileDownloader, @unchecked Sendable {
        let contents: String
        private(set) var calls = 0

        init(contents: String = "archive-bytes") {
            self.contents = contents
        }

        func download(
            from _: URL,
            to destination: URL,
            resumeData _: Data?,
            progress: @Sendable @escaping (Int64, Int64?) -> Void
        ) async throws -> Int64 {
            calls += 1
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: destination)
            progress(Int64(contents.utf8.count), Int64(contents.utf8.count))
            return Int64(contents.utf8.count)
        }
    }

    private func feed(_ body: String) -> UpdateFeed {
        UpdateFeed(
            client: MockHTTP { _, _, _ in HTTPResponse(status: 200, body: Data(body.utf8)) },
            endpoint: URL(string: "https://example.invalid/latest")!
        )
    }

    private func payload(_ version: String) -> String {
        #"{"version":"\#(version)","url":"https://downloads.claude.ai/\#(version)/Claude.zip"}"#
    }

    /// A runner whose `ditto` plants a plausible bundle and whose signing tools approve.
    private func runner(version: String) -> RecordingCommandRunner {
        RecordingCommandRunner { executable, arguments in
            if executable == CoreConstants.dittoPath, let destination = arguments.last {
                let app = URL(fileURLWithPath: destination).appendingPathComponent("Claude.app")
                let contents = app.appendingPathComponent("Contents")
                try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                let plist: [String: Any] = [
                    "CFBundleShortVersionString": version,
                    "CFBundleIdentifier": "com.anthropic.claudefordesktop"
                ]
                let data = try? PropertyListSerialization.data(
                    fromPropertyList: plist,
                    format: .xml,
                    options: 0
                )
                try? data?.write(to: contents.appendingPathComponent("Info.plist"))
            }
            return CommandOutput(exitCode: 0, standardOutput: "", standardError: "")
        }
    }

    private func makeService(
        feedBody: String,
        version: String,
        downloader stub: StubDownloader = StubDownloader()
    ) throws -> (service: ClaudeUpdateService, root: URL) {
        let root = fm.temporaryDirectory.appendingPathComponent("cm-service-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let service = ClaudeUpdateService(
            feed: feed(feedBody),
            downloader: UpdateDownloader(downloader: stub, cacheDirectory: root),
            verifier: UpdateVerifier(runner: runner(version: version)),
            stagingDirectory: root.appendingPathComponent("staged")
        )
        return (service, root)
    }

    // MARK: - Checking

    @Test
    func offersAReleaseNewerThanWhatIsInstalled() async throws {
        let (service, root) = try makeService(feedBody: payload("1.37937.1"), version: "1.37937.1")
        defer { try? fm.removeItem(at: root) }

        let update = try await service.checkForUpdate(installedVersion: "1.30096.5")

        #expect(update?.version == "1.37937.1")
    }

    @Test(arguments: ["1.37937.1", "1.40000.0"])
    func offersNothingWhenTheInstalledBuildIsCurrentOrNewer(_ installed: String) async throws {
        let (service, root) = try makeService(feedBody: payload("1.37937.1"), version: "1.37937.1")
        defer { try? fm.removeItem(at: root) }

        #expect(try await service.checkForUpdate(installedVersion: installed) == nil)
    }

    /// "There is no update" and "I could not ask" must not collapse into one answer — that
    /// is how a broken feed comes to look like a machine that is up to date.
    @Test
    func throwsRatherThanReportingNoUpdateWhenTheFeedFails() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("cm-service-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let service = try ClaudeUpdateService(
            feed: UpdateFeed(
                client: MockHTTP { _, _, _ in throw URLError(.notConnectedToInternet) },
                endpoint: #require(URL(string: "https://example.invalid/latest"))
            ),
            downloader: UpdateDownloader(downloader: StubDownloader(), cacheDirectory: root),
            verifier: UpdateVerifier(runner: runner(version: "1.0.0")),
            stagingDirectory: root.appendingPathComponent("staged")
        )

        await #expect(throws: URLError.self) {
            _ = try await service.checkForUpdate(installedVersion: "1.0.0")
        }
    }

    // MARK: - Preparing

    @Test
    func leavesAVerifiedBundleReadyToInstall() async throws {
        let (service, root) = try makeService(feedBody: payload("1.37937.1"), version: "1.37937.1")
        defer { try? fm.removeItem(at: root) }
        let update = try #require(try await service.checkForUpdate(installedVersion: "1.30096.5"))

        let verified = try await service.prepare(update)

        #expect(verified.version == "1.37937.1")
        #expect(fm.fileExists(atPath: verified.appURL.path))
    }

    @Test
    func reportsDownloadProgress() async throws {
        let (service, root) = try makeService(feedBody: payload("1.37937.1"), version: "1.37937.1")
        defer { try? fm.removeItem(at: root) }
        let update = try #require(try await service.checkForUpdate(installedVersion: "1.30096.5"))
        let seen = Reported()

        _ = try await service.prepare(update) { received, _ in seen.record(received) }

        // The stub reports once; what matters is that the callback is wired through at all.
        #expect(seen.highWaterMark > 0)
    }

    /// A second pass after an interruption continues rather than re-fetching, but must not
    /// skip the proof: the archive has been sitting on disk since, and it is the entire basis
    /// for replacing the user's app.
    @Test
    func verifiesAgainEvenWhenTheArchiveWasAlreadyDownloaded() async throws {
        let stub = StubDownloader()
        let (service, root) = try makeService(
            feedBody: payload("1.37937.1"), version: "1.37937.1", downloader: stub
        )
        defer { try? fm.removeItem(at: root) }
        let update = try #require(try await service.checkForUpdate(installedVersion: "1.30096.5"))

        _ = try await service.prepare(update)
        let second = try await service.prepare(update)

        #expect(stub.calls == 1, "the archive should not be fetched twice")
        #expect(fm.fileExists(atPath: second.appURL.path))
    }

    /// A bundle that fails its checks never becomes something the install step could pick up.
    @Test
    func leavesNothingStagedWhenVerificationFails() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("cm-service-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let staging = root.appendingPathComponent("staged")
        let service = ClaudeUpdateService(
            feed: feed(payload("1.37937.1")),
            downloader: UpdateDownloader(downloader: StubDownloader(), cacheDirectory: root),
            // Signed by somebody, but not by Anthropic.
            verifier: UpdateVerifier(runner: RecordingCommandRunner { executable, arguments in
                if executable == CoreConstants.dittoPath, let destination = arguments.last {
                    try? FileManager.default.createDirectory(
                        at: URL(fileURLWithPath: destination).appendingPathComponent("Claude.app"),
                        withIntermediateDirectories: true
                    )
                }
                if executable == CoreConstants.codesignPath, arguments.contains("-R") {
                    return CommandOutput(exitCode: 1, standardOutput: "", standardError: "refused")
                }
                return CommandOutput(exitCode: 0, standardOutput: "", standardError: "")
            }),
            stagingDirectory: staging
        )
        let update = try #require(try await service.checkForUpdate(installedVersion: "1.30096.5"))

        await #expect(throws: UpdateVerifier.Failure.self) { _ = try await service.prepare(update) }
        #expect(!fm.fileExists(atPath: staging.path))
    }

    // MARK: - Discarding

    @Test
    func discardsBothTheArchiveAndTheUnpackedBundle() async throws {
        let (service, root) = try makeService(feedBody: payload("1.37937.1"), version: "1.37937.1")
        defer { try? fm.removeItem(at: root) }
        let update = try #require(try await service.checkForUpdate(installedVersion: "1.30096.5"))
        let verified = try await service.prepare(update)
        #expect(fm.fileExists(atPath: verified.appURL.path))

        service.discardEverything()

        #expect(!fm.fileExists(atPath: verified.appURL.path))
        #expect((try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty == true)
    }
}

/// Collects what the progress callback reported.
///
/// A lock rather than an actor: the callback is synchronous, so hopping onto an actor would
/// mean spawning a `Task` whose completion the test cannot wait for — which is a flake, not a
/// test.
private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    func record(_ bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        value = max(value, bytes)
    }

    var highWaterMark: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
