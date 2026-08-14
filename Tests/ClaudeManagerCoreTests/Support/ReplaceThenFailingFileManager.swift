import Foundation

/// Performs the atomic swap and *then* reports it as failed.
///
/// The case `LauncherBundle.build`'s undo has to tell apart: a `replaceItemAt` that throws having
/// already put the staged bundle in place. Undoing the spelling change there would move the new
/// bundle — new marker, new settings — under the old name, manufacturing the split identity the
/// undo exists to prevent. Only a stub can produce it; the real call gives no way to fail after
/// its own commit point on demand.
final class ReplaceThenFailingFileManager: FileManager, @unchecked Sendable {
    /// The reason a caller is expected to carry into whatever it reports.
    static let message = "The bundle was replaced, then something went wrong."

    override func replaceItem(
        at originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String?,
        options: FileManager.ItemReplacementOptions = [],
        resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        try super.replaceItem(
            at: originalItemURL,
            withItemAt: newItemURL,
            backupItemName: backupItemName,
            options: options,
            resultingItemURL: resultingItemURL
        )
        throw stubbedWriteFailure(Self.message)
    }
}
