import Foundation

/// Refuses to rename a `.app`, and nothing else.
///
/// `LauncherBundle.build` renames the installed bundle when the spelling it was asked for is not
/// the one on disk, and that step is deliberately placed **before** the atomic swap so a failure
/// leaves the previous launcher whole. Only a stubbed failure can assert that, since the real
/// call fails on races and permissions a test cannot arrange.
///
/// The filter is `.app` on the *source*, which is exactly the rename under test: the staging
/// build directory is named `.<name>.app.build-<uuid>`, so `build`'s other `moveItem` — the one
/// installing to a fresh path — is left working.
final class RenameRefusingFileManager: FileManager, @unchecked Sendable {
    /// The reason a caller is expected to carry into whatever it reports.
    static let message = "This bundle cannot be renamed."

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        guard srcURL.pathExtension == "app" else {
            try super.moveItem(at: srcURL, to: dstURL)
            return
        }
        throw stubbedWriteFailure(Self.message)
    }
}
