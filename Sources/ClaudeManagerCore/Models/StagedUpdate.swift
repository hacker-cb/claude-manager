import Foundation

/// A Claude Desktop update that ShipIt has **staged but not yet applied** — downloaded
/// and armed, waiting for every `com.anthropic.claudefordesktop` instance to quit so it
/// can swap `/Applications/Claude.app`. Any open clone blocks it, which is exactly the
/// "Update didn't complete" case this surfaces.
///
/// Distinct from `ManagedProfile.claudeUpdateAvailable` (running-vs-installed skew): here
/// the swap never happened, so installed still equals running — nothing surfaces from a
/// version comparison, but the staged bundle sits on disk ready to apply.
public struct StagedUpdate: Equatable, Sendable {
    /// `CFBundleShortVersionString` of the staged bundle.
    public let stagedVersion: String
    /// The version currently installed at `/Applications/Claude.app`, if readable.
    public let installedVersion: String?
    /// The staged bundle on disk (ShipIt's `updateBundleURL`).
    public let stagedBundleURL: URL

    public init(stagedVersion: String, installedVersion: String?, stagedBundleURL: URL) {
        self.stagedVersion = stagedVersion
        self.installedVersion = installedVersion
        self.stagedBundleURL = stagedBundleURL
    }

    /// Whether the staged bundle is a genuine upgrade over what's installed — so a
    /// re-stage of the current version, or an older rollback bundle, is not offered.
    public var isUpgrade: Bool {
        guard let installedVersion else { return true }
        return VersionOrder.isNewer(stagedVersion, than: installedVersion)
    }
}
