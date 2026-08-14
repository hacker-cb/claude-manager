import Foundation

/// Fails the atomic swap `LauncherBundle.build` finishes with, and nothing else.
///
/// The swap is the last thing that can go wrong after `alignInstalledSpelling` has already
/// renamed the installed bundle — the one part of a failed build that does not undo itself, since
/// the launcher would be left answering to a name its own marker does not know.
final class ReplaceRefusingFileManager: FileManager, @unchecked Sendable {
    /// The reason a caller is expected to carry into whatever it reports.
    static let message = "This bundle cannot be replaced."

    /// The `@objc` method behind `replaceItemAt(_:withItemAt:)` — that spelling is a Swift
    /// wrapper declared in an extension, which cannot be overridden; this is the one the
    /// wrapper calls.
    override func replaceItem(
        at _: URL,
        withItemAt _: URL,
        backupItemName _: String?,
        options _: FileManager.ItemReplacementOptions = [],
        resultingItemURL _: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        throw stubbedWriteFailure(Self.message)
    }
}
