import Foundation

/// A `FileManager` that revokes a directory's **listing** permission as a side effect of
/// `trashItem`.
///
/// `remove` answers "does anyone else use this profile's data" twice: once before trashing the
/// launcher, and again inside the purge. Only the second one can be reached with the folder in
/// a different state than the first saw, and no test can hit that window by timing. `trashItem`
/// is exactly what runs between them, so revoking the listing there reproduces the race
/// deterministically. Traversal is left in place, so paths inside the folder stay reachable —
/// what changes is only that the folder can no longer be enumerated.
///
/// Separate file: `TestSupport.swift` is at its length cap.
final class ListingRevokingFileManager: FileManager, @unchecked Sendable {
    private let directory: String

    init(revokeListingOf directory: String) {
        self.directory = directory
        super.init()
    }

    override func trashItem(
        at url: URL,
        resultingItemURL outURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        try super.trashItem(at: url, resultingItemURL: outURL)
        try? super.setAttributes([.posixPermissions: 0o311], ofItemAtPath: directory)
    }
}
