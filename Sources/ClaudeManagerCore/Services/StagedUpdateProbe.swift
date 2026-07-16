import Foundation

/// Detects a staged-but-unapplied Claude Desktop update by reading ShipIt's job state.
///
/// ShipIt writes `ShipItState.plist` (**JSON**, despite the extension) under
/// `~/Library/Caches/<bundleid>.ShipIt/` when an install job is armed; its
/// `updateBundleURL` points at the downloaded `Claude.app` waiting to be swapped in. We
/// read that bundle's version and compare it with what's installed. All parsing is
/// defensive — any missing file, malformed JSON, or absent bundle yields `nil`.
public struct StagedUpdateProbe {
    let realClaude: RealClaude
    let shipItStatePath: String
    let fileManager: FileManager

    public init(
        realClaude: RealClaude,
        shipItStatePath: String,
        fileManager: FileManager = .default
    ) {
        self.realClaude = realClaude
        self.shipItStatePath = shipItStatePath
        self.fileManager = fileManager
    }

    /// The staged update, or `nil` when there is no armed job, the staged bundle is gone,
    /// or the staged version is not a genuine upgrade (a re-stage of the current version
    /// or an older rollback bundle is never offered).
    public func probe() -> StagedUpdate? {
        guard let bundleURL = stagedBundleURL(),
              let stagedVersion = Self.bundleVersion(at: bundleURL, fileManager: fileManager)
        else { return nil }
        let update = StagedUpdate(
            stagedVersion: stagedVersion,
            installedVersion: realClaude.version(fileManager: fileManager),
            stagedBundleURL: bundleURL
        )
        return update.isUpgrade ? update : nil
    }

    /// The armed `updateBundleURL` from `ShipItState.plist`, if it exists on disk.
    private func stagedBundleURL() -> URL? {
        guard let data = fileManager.contents(atPath: shipItStatePath),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let urlString = dict["updateBundleURL"] as? String,
              let url = Self.fileURL(from: urlString),
              fileManager.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Resolve `updateBundleURL` to a file URL. ShipIt writes a `file://` URL, but accept a
    /// plain absolute path too, so a wire-format change can't make a staged bundle invisible.
    private static func fileURL(from string: String) -> URL? {
        if let url = URL(string: string), url.isFileURL { return url }
        return string.hasPrefix("/") ? URL(fileURLWithPath: string) : nil
    }

    /// `CFBundleShortVersionString` of the bundle at `bundleURL`, if readable.
    static func bundleVersion(at bundleURL: URL, fileManager: FileManager) -> String? {
        RealClaude.plist(
            at: bundleURL.appendingPathComponent("Contents/Info.plist"),
            fileManager: fileManager
        )?["CFBundleShortVersionString"] as? String
    }
}
