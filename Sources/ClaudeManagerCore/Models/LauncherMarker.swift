import Foundation

/// The dictionary stored under `CoreConstants.markerKey` inside a launcher's
/// Info.plist. This — not any external file — is the source of truth for a
/// launcher's identity and is what `scan` reads back.
public struct LauncherMarker: Equatable, Sendable {
    public var name: String
    public var label: String
    public var color: String
    public var profile: String
    /// Version of the wrapper (script + Info.plist) that built this launcher, so a
    /// bundle from an older Claude Manager reads back as stale — see
    /// `CoreConstants.currentWrapperVersion`.
    public var wrapperVersion: Int

    public init(
        name: String,
        label: String,
        color: String,
        profile: String,
        wrapperVersion: Int = CoreConstants.currentWrapperVersion
    ) {
        self.name = name
        self.label = label
        self.color = color
        self.profile = profile
        self.wrapperVersion = wrapperVersion
    }

    /// Plist-serializable representation embedded into the Info.plist.
    public var dictionary: [String: Any] {
        [
            "name": name,
            "label": label,
            "color": color,
            "profile": profile,
            "wrapperVersion": wrapperVersion
        ]
    }

    /// Reconstruct from a plist dictionary; `nil` if required keys are absent
    /// (i.e. the bundle is not one of ours).
    public init?(dictionary: [String: Any]) {
        guard
            let name = dictionary["name"] as? String,
            let label = dictionary["label"] as? String,
            let color = dictionary["color"] as? String,
            let profile = dictionary["profile"] as? String
        else { return nil }
        self.name = name
        self.label = label
        self.color = color
        self.profile = profile
        // A bundle built before wrapper versioning existed has no key — treat it as
        // v1 so it reads back as stale against the current version.
        wrapperVersion = (dictionary["wrapperVersion"] as? Int) ?? 1
    }
}
