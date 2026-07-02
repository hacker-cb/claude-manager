import Foundation

/// GUI-only, non-authoritative metadata for a launcher, keyed by bundle id. The
/// launcher's Info.plist marker remains the source of truth for mechanics; this
/// only augments it with things the UI cares about (ordering, free-form notes) and
/// the app works fully if this file is missing or deleted.
public struct LauncherMetadata: Codable, Equatable, Sendable {
    public var order: Int?
    public var notes: String?

    public init(order: Int? = nil, notes: String? = nil) {
        self.order = order
        self.notes = notes
    }
}

/// Reads/writes the metadata JSON in Application Support.
public struct MetadataStore {
    let fileManager: FileManager
    public let fileURL: URL

    public init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        let base = directory ?? Self.defaultDirectory(fileManager: fileManager)
        fileURL = base.appendingPathComponent("metadata.json")
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(CoreConstants.appSupportDirectoryName, isDirectory: true)
    }

    public func load() -> [String: LauncherMetadata] {
        guard let data = fileManager.contents(atPath: fileURL.path),
              let decoded = try? JSONDecoder().decode([String: LauncherMetadata].self, from: data)
        else { return [:] }
        return decoded
    }

    public func save(_ metadata: [String: LauncherMetadata]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: fileURL, options: .atomic)
    }

    /// Read-modify-write a single launcher's metadata.
    public func update(bundleID: String, _ transform: (inout LauncherMetadata) -> Void) throws {
        var all = load()
        var entry = all[bundleID] ?? LauncherMetadata()
        transform(&entry)
        all[bundleID] = entry
        try save(all)
    }
}
