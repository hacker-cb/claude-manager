import Foundation

/// A `FileManager` that makes one bundle unreadable as a side effect of `trashItem` — the
/// operation that runs between `remove`'s two scans.
///
/// The window it reproduces is real and untimeable: a sibling readable when the removal decides
/// whether to refuse, and unreadable when the purge decides whether to delete. Only the second
/// scan would see it gone, and a purge that trusts only that scan deletes the directory the
/// sibling still claims.
///
/// Separate file: `TestSupport.swift` is at its length cap.
final class SiblingHidingFileManager: FileManager, @unchecked Sendable {
    private let bundlePath: String

    init(hideOnTrash bundlePath: String) {
        self.bundlePath = bundlePath
        super.init()
    }

    override func trashItem(
        at url: URL,
        resultingItemURL outURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        try super.trashItem(at: url, resultingItemURL: outURL)
        try? super.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bundlePath)
    }
}
