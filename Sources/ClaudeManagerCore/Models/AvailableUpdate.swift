import Foundation

/// A Claude Desktop release the update feed is offering, and where to fetch it.
///
/// Deliberately just the two fields the feed guarantees. Its sibling endpoint
/// (`squirrel/update`) also returns `sha256`, `size` and release notes, but it requires a
/// per-profile `device_id` and answers with the build rolled out to *that device* rather
/// than the newest one — see ``UpdateFeed`` for why this app asks for the latest instead.
/// Anything the payload carries beyond these fields is ignored, so a server-side addition
/// cannot break parsing.
public struct AvailableUpdate: Equatable, Sendable {
    /// `CFBundleShortVersionString` of the offered build, e.g. `1.37937.1`.
    public let version: String
    /// The `.zip` holding `Claude.app` at its top level.
    public let downloadURL: URL

    public init(version: String, downloadURL: URL) {
        self.version = version
        self.downloadURL = downloadURL
    }

    /// Whether this release is strictly newer than what is installed.
    ///
    /// An unreadable installed version answers **false**: we cannot confirm an upgrade
    /// against an unknown baseline, and offering one would risk replacing a working
    /// `/Applications/Claude.app` with an older build.
    ///
    /// "Unreadable" covers more than `nil`. `RealClaude.version()` reads
    /// `CFBundleShortVersionString` with `as? String`, so a bundle caught mid-write — or
    /// one whose plist simply carries an empty value — yields `""`, not `nil`. Passed
    /// straight to `VersionOrder` that compares as all-zeroes and every release reads as an
    /// upgrade, which is precisely the case this guard exists to refuse. So the baseline
    /// must parse as a version, not merely be non-nil.
    public func isUpgrade(over installedVersion: String?) -> Bool {
        guard let installedVersion, VersionOrder.isComparable(installedVersion) else { return false }
        return VersionOrder.isNewer(version, than: installedVersion)
    }
}
