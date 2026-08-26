import Foundation

/// Clears what Claude's own updater leaves behind once it is switched off.
///
/// Turning `disableAutoUpdates` on stops Squirrel arming again, but it does not tidy up after
/// the last time it ran: an armed job in `ShipItState.plist` and the downloaded bundle it
/// points at both survive. That bundle is several hundred megabytes of a build that will now
/// never be installed by anybody — this app installs its own — and the armed job is worse
/// than dead weight, because anything that starts Squirrel again would act on it.
///
/// Deliberately narrow. It touches only ShipIt's own cache directory, and only the state file
/// and the `update.*` staging directories that ShipIt itself creates there.
///
/// Not `Sendable`: it holds a `FileManager`, like the core's other filesystem services, and
/// every method on it is synchronous, so it never leaves the actor that owns it.
public struct SquirrelResidue {
    /// What a sweep found and removed.
    public struct Outcome: Equatable, Sendable {
        /// Whether an armed job was cleared.
        public let clearedArmedJob: Bool
        /// Staging directories removed, by name.
        public let removedStagedBundles: [String]
        /// Bytes reclaimed, as far as they could be measured.
        public let reclaimedBytes: Int64

        public var changedAnything: Bool {
            clearedArmedJob || !removedStagedBundles.isEmpty
        }
    }

    let statePath: String
    let fileManager: FileManager

    public init(statePath: String, fileManager: FileManager = .default) {
        self.statePath = statePath
        self.fileManager = fileManager
    }

    /// Remove the armed job and any staged bundle beside it.
    ///
    /// Safe to run repeatedly and safe to run when Squirrel is still in charge of updating —
    /// it would simply re-download. Not safe to run *while ShipIt is installing*, which is
    /// the caller's business to establish; removing the bundle out from under a live
    /// installer is the failure this whole rewrite exists to stop causing.
    @discardableResult
    public func sweep() -> Outcome {
        let directory = URL(fileURLWithPath: statePath).deletingLastPathComponent()
        var reclaimed: Int64 = 0
        var removed: [String] = []

        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.stagingPrefix) {
            let url = directory.appendingPathComponent(name)
            let size = Self.directorySize(url, fileManager: fileManager)
            do {
                try fileManager.removeItem(at: url)
                removed.append(name)
                reclaimed += size
                CoreLog.update.info("squirrel: removed staged bundle \(name, privacy: .public)")
            } catch {
                CoreLog.update.error(
                    """
                    squirrel: could not remove \(name, privacy: .public) \
                    — \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }

        var clearedJob = false
        if fileManager.fileExists(atPath: statePath) {
            do {
                try fileManager.removeItem(atPath: statePath)
                clearedJob = true
                CoreLog.update.info("squirrel: cleared the armed install job")
            } catch {
                CoreLog.update.error(
                    "squirrel: could not clear the armed job — \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return Outcome(clearedArmedJob: clearedJob, removedStagedBundles: removed, reclaimedBytes: reclaimed)
    }

    /// ShipIt names its staging directories `update.<random>`.
    static let stagingPrefix = "update."

    /// Total size of a directory tree, best-effort — used only to report what was reclaimed.
    private static func directorySize(_ url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            let size = try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize
            total += Int64(size ?? 0)
        }
        return total
    }
}
