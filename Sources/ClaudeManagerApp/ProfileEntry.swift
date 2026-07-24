import ClaudeManagerCore

/// One row in every profile list — the default profile and each managed clone rendered as
/// peers. The default profile is *not* a `ManagedProfile`: it has no launcher bundle, so it
/// offers no edit / remove / rebuild, only open / activate / stop.
enum ProfileEntry: Identifiable {
    case primary(PrimaryProfileStatus)
    case clone(ManagedProfile)

    /// Selection id for the default-profile row. A clone's id is its launcher `appPath`
    /// (an absolute filesystem path), so this literal can never collide with one.
    static let primaryID = "__default__"

    var id: String {
        switch self {
        case .primary: Self.primaryID
        case let .clone(managed): managed.id
        }
    }
}
