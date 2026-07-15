import Foundation

/// Reads and writes Claude Manager's per-profile managed-config overlay in a clone's
/// **local config tier** (`<userData>-3p/configLibrary`).
///
/// Merge-not-clobber and idempotent: it reuses an existing `_meta.json` `appliedId`
/// (or mints a v4 UUID), then merges our keys into `<appliedId>.json` while
/// preserving every key we don't own. All parsing is defensive (nil / skip on
/// failure) so a Claude schema change never crashes normal operation, and writes are
/// skipped when the bytes are unchanged so the reconcile-on-every-launch path
/// doesn't churn files Claude may be reading.
public struct ManagedConfigWriter {
    /// What a reconcile did, for surfacing / assertion.
    public enum Outcome: Equatable, Sendable {
        /// Overlay is in place (written, or already matched — idempotent).
        case reconciled(configLibrary: URL, appliedID: String)
        /// An MDM managed-preferences plist is present: the managed tier overrides the
        /// local one, so writing here would be ignored. The tree is left untouched.
        case skippedMDMPresent
    }

    let fileManager: FileManager
    /// System MDM managed-preferences plists for Claude (one per wrapped bundle id).
    /// When any exists the local tier is overridden; injectable so tests can point at
    /// temp paths (and so the check never depends on the developer's real machine state).
    let managedPreferencesURLs: [URL]

    public init(
        fileManager: FileManager = .default,
        managedPreferencesURLs: [URL] = CoreConstants.claudeManagedPreferencesPaths
            .map { URL(fileURLWithPath: $0) }
    ) {
        self.fileManager = fileManager
        self.managedPreferencesURLs = managedPreferencesURLs
    }

    // MARK: - Path derivation

    /// `<userData>-3p/configLibrary` — the local config tier Claude reads for a
    /// `--user-data-dir=<userData>` instance. The `-3p` suffix is appended to the
    /// user-data path string exactly as Claude's resolver does, yielding a sibling
    /// dir (e.g. `…/work` → `…/work-3p`). A trailing slash is trimmed first so the
    /// suffix lands on the directory name, not after the separator.
    public static func configLibraryURL(forUserDataPath userDataPath: String) -> URL {
        localTierURL(forUserDataPath: userDataPath)
            .appendingPathComponent("configLibrary", isDirectory: true)
    }

    /// The `-3p` sibling root for a user-data dir (parent of `configLibrary`) — the
    /// whole local tier, removed wholesale when the profile's data is purged.
    public static func localTierURL(forUserDataPath userDataPath: String) -> URL {
        var base = userDataPath
        while base.count > 1, base.hasSuffix("/") {
            base.removeLast()
        }
        return URL(fileURLWithPath: base + "-3p", isDirectory: true)
    }

    // MARK: - Queries

    /// True when Claude is MDM-managed (any known bundle-id plist present), so a local
    /// overlay would be ignored.
    public var mdmPresent: Bool {
        presentManagedPreferencesURL != nil
    }

    /// The MDM plist that made `mdmPresent` true, for surfacing in a `Doctor` note.
    public var presentManagedPreferencesURL: URL? {
        managedPreferencesURLs.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// Whether a local tier already exists for this user-data dir (its `_meta.json` is
    /// present). Lets a caller avoid *materializing* an empty overlay in an
    /// otherwise-untouched account (e.g. the default account when the broker is off).
    public func overlayExists(userDataPath: String) -> Bool {
        let meta = Self.configLibraryURL(forUserDataPath: userDataPath)
            .appendingPathComponent("_meta.json")
        return fileManager.fileExists(atPath: meta.path)
    }

    /// Whether the on-disk overlay already satisfies `config` — every wanted flat key
    /// present with the wanted value. Used by `Doctor` to spot a clone whose overlay
    /// is missing (e.g. a best-effort write that silently failed). MDM presence counts
    /// as satisfied: the managed tier is expected to take over there.
    public func isSatisfied(_ config: ProfileManagedConfig, userDataPath: String) -> Bool {
        if mdmPresent { return true }
        let configLibrary = Self.configLibraryURL(forUserDataPath: userDataPath)
        guard let appliedID = readAppliedID(at: configLibrary.appendingPathComponent("_meta.json")),
              let current = readJSONObject(at: configLibrary.appendingPathComponent("\(appliedID).json"))
        else { return config.flatEntries.isEmpty }
        return config.flatEntries.allSatisfy { key, value in
            (current[key] as? Bool) == value
        }
    }

    // MARK: - Mutations

    /// Write `config` into the clone's local tier. No-op (returns `.skippedMDMPresent`)
    /// when an MDM plist is present. Throws only on genuine IO failure.
    @discardableResult
    public func reconcile(
        _ config: ProfileManagedConfig,
        userDataPath: String
    ) throws -> Outcome {
        if mdmPresent { return .skippedMDMPresent }
        let configLibrary = Self.configLibraryURL(forUserDataPath: userDataPath)
        try fileManager.createDirectory(at: configLibrary, withIntermediateDirectories: true)

        let appliedID = try resolveAppliedID(in: configLibrary)
        let configFile = configLibrary.appendingPathComponent("\(appliedID).json")
        try mergeAndWrite(config, into: configFile)
        return .reconciled(configLibrary: configLibrary, appliedID: appliedID)
    }

    /// Delete the entire `-3p` local tier for a user-data dir (used when the profile
    /// data is purged). Silent no-op when absent.
    public func removeOverlay(userDataPath: String) throws {
        let tier = Self.localTierURL(forUserDataPath: userDataPath)
        if fileManager.fileExists(atPath: tier.path) {
            try fileManager.removeItem(at: tier)
        }
    }

    // MARK: - Internals

    /// Reuse a valid existing `appliedId`, else mint a v4 UUID and persist it. Merges
    /// into `_meta.json` rather than clobbering it, so any sibling keys Claude may keep
    /// there survive a re-mint (same merge-preserve discipline as the config file).
    private func resolveAppliedID(in configLibrary: URL) throws -> String {
        let metaURL = configLibrary.appendingPathComponent("_meta.json")
        if let existing = readAppliedID(at: metaURL) {
            return existing
        }
        let minted = UUID().uuidString.lowercased()
        var meta = readJSONObject(at: metaURL) ?? [:]
        meta["appliedId"] = minted
        try writeJSONIfChanged(meta, to: metaURL)
        return minted
    }

    private func readAppliedID(at metaURL: URL) -> String? {
        guard let dict = readJSONObject(at: metaURL),
              let applied = dict["appliedId"] as? String,
              Self.isValidAppliedID(applied)
        else { return nil }
        return applied
    }

    /// Matches Claude's own `appliedId` gate — its regex `/^[a-f0-9-]{36}$/` — rather
    /// than a strict UUID: 36 chars each in `[a-f0-9-]` (the shape a lowercased v4 UUID
    /// takes, but hyphen positions are deliberately *not* enforced, to mirror Claude
    /// exactly and reuse whatever id it already applied). Its only use is as a safe path
    /// component, and `[a-f0-9-]{36}` cannot contain `/`, `.`, or `..`.
    static func isValidAppliedID(_ id: String) -> Bool {
        id.count == 36 && id.unicodeScalars.allSatisfy { scalar in
            (scalar >= "a" && scalar <= "f") || (scalar >= "0" && scalar <= "9") || scalar == "-"
        }
    }

    /// Merge our flat keys into the config file, preserving unknown keys. First drops
    /// every key we *own* (so a toggled-off setting is cleaned up), then sets the keys
    /// we currently want present.
    private func mergeAndWrite(_ config: ProfileManagedConfig, into configFile: URL) throws {
        var merged = readJSONObject(at: configFile) ?? [:]
        for key in ProfileManagedConfig.managedKeys {
            merged.removeValue(forKey: key)
        }
        for (key, value) in config.flatEntries {
            merged[key] = value
        }
        try writeJSONIfChanged(merged, to: configFile)
    }

    /// Defensive JSON-object read: nil on missing/unreadable/non-object content, so a
    /// malformed file is treated as empty rather than throwing.
    private func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = fileManager.contents(atPath: url.path),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { return nil }
        return dict
    }

    /// Write `object` as pretty, key-sorted JSON only when it differs from what's on
    /// disk — a true no-op when nothing changed keeps the reconcile-per-launch path
    /// from rewriting a file Claude might be reading. Returns whether it wrote.
    @discardableResult
    private func writeJSONIfChanged(_ object: [String: Any], to url: URL) throws -> Bool {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        if let existing = fileManager.contents(atPath: url.path), existing == data {
            return false
        }
        try data.write(to: url, options: .atomic)
        return true
    }
}
