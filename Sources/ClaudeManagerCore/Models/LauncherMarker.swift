import Foundation

/// The dictionary stored under `CoreConstants.markerKey` inside a launcher's
/// Info.plist. This — not any external file — is the source of truth for a
/// launcher's identity and is what `scan` reads back.
public struct LauncherMarker: Equatable, Sendable {
    public var name: String
    public var label: String
    public var color: String
    public var profile: String
    public var schemaVersion: Int

    public init(
        name: String,
        label: String,
        color: String,
        profile: String,
        schemaVersion: Int = CoreConstants.markerSchemaVersion
    ) {
        self.name = name
        self.label = label
        self.color = color
        self.profile = profile
        self.schemaVersion = schemaVersion
    }

    /// Plist-serializable representation embedded into the Info.plist.
    public var dictionary: [String: Any] {
        [
            "name": name,
            "label": label,
            "color": color,
            "profile": profile,
            "schemaVersion": schemaVersion
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
        schemaVersion = (dictionary["schemaVersion"] as? Int) ?? 1
    }
}
