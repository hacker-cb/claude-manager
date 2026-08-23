import Foundation
@testable import ClaudeManagerCore

// MARK: - Managed-config overlay test helpers

/// Seed a raw managed-config overlay the way an earlier build would have — arbitrary flat
/// keys, including ones the current model no longer writes (so their cleanup can be tested).
func seedRawOverlay(
    _ entries: [String: Bool],
    userDataPath: String,
    fileManager: FileManager = .default
) throws {
    let library = ManagedConfigWriter.configLibraryURL(forUserDataPath: userDataPath)
    try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
    let appliedID = "00000000-0000-4000-8000-000000000000" // valid per isValidAppliedID
    try JSONSerialization.data(withJSONObject: ["appliedId": appliedID])
        .write(to: library.appendingPathComponent("_meta.json"))
    try JSONSerialization.data(withJSONObject: entries)
        .write(to: library.appendingPathComponent("\(appliedID).json"))
}

/// Seed a raw overlay carrying **non-boolean** values — the shape `ManagedConfigWriter.integer`
/// reads, and the one a policy like `autoUpdaterEnforcementHours` actually arrives in.
///
/// Throws rather than swallowing a setup failure: a fixture that silently wrote nothing turns
/// into a confusing assertion failure downstream — or a test that passes without ever reading
/// an overlay at all.
func seedRawOverlayValues(
    _ entries: [String: Any],
    userDataPath: String,
    fileManager: FileManager = .default
) throws {
    let library = ManagedConfigWriter.configLibraryURL(forUserDataPath: userDataPath)
    try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
    let appliedID = "00000000-0000-4000-8000-000000000000"
    try JSONSerialization.data(withJSONObject: ["appliedId": appliedID])
        .write(to: library.appendingPathComponent("_meta.json"))
    try JSONSerialization.data(withJSONObject: entries)
        .write(to: library.appendingPathComponent("\(appliedID).json"))
}

/// Read the raw flat overlay dict for a user-data dir (`nil` if none). Lets a test assert a
/// specific key's presence/absence, not just that a `ProfileManagedConfig` is satisfied.
func rawOverlay(_ userDataPath: String, fileManager: FileManager = .default) -> [String: Any]? {
    let library = ManagedConfigWriter.configLibraryURL(forUserDataPath: userDataPath)
    guard let metaData = fileManager.contents(atPath: library.appendingPathComponent("_meta.json").path),
          let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
          let appliedID = meta["appliedId"] as? String,
          let data = fileManager.contents(atPath: library.appendingPathComponent("\(appliedID).json").path),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return dict
}

// MARK: - A FileManager whose Trash is broken

/// Fails `trashItem` and behaves like `FileManager.default` for everything else.
///
/// The real thing fails for reasons a test cannot arrange without touching the machine — a
/// volume with no Trash, a file another process holds open, a revoked permission — and a
/// rename's Trash step is exactly the operation whose failure the store has to report rather
/// than swallow. Subclassing reaches it because every caller goes through the injected
/// instance, so nothing else in the store is disturbed.
/// The failure a stubbed `FileManager` reports when it refuses a write.
///
/// One shape for all of them, so changing how stubbed filesystem failures look — a different
/// domain, an errno-bearing `userInfo` a test can assert on — is one edit rather than four, and
/// each stub is left as nothing but the method it overrides.
func stubbedWriteFailure(_ message: String) -> NSError {
    NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileWriteUnknownError,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

final class TrashRefusingFileManager: FileManager, @unchecked Sendable {
    /// The reason the store is expected to carry into its report.
    static let message = "The Trash is unavailable on this volume."

    override func trashItem(
        at _: URL,
        resultingItemURL _: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        throw stubbedWriteFailure(Self.message)
    }
}

/// Refuses the Trash *and* reports every removal as failed after performing it — standing in
/// for a rollback whose target is already gone by the time the error comes back.
final class TrashRefusingLosingRemovalsFileManager: FileManager, @unchecked Sendable {
    override func trashItem(
        at _: URL,
        resultingItemURL _: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        throw stubbedWriteFailure(TrashRefusingFileManager.message)
    }

    override func removeItem(at url: URL) throws {
        try super.removeItem(at: url)
        throw NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "The file doesn’t exist."]
        )
    }
}

/// Deletes the item outright and *then* fails — standing in for the race where something else
/// removes the bundle between the store's existence check and its Trash call.
final class TrashVanishingFileManager: FileManager, @unchecked Sendable {
    override func trashItem(
        at url: URL,
        resultingItemURL _: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        try? removeItem(at: url)
        throw NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "The file doesn’t exist."]
        )
    }
}
