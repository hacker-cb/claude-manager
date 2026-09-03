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

    /// Selection id for the Limits page — the sidebar's one row that is not a profile at all.
    ///
    /// A sentinel beside the one above rather than a case of this enum: `ProfileEntry` is what
    /// the menu bar renders too, and a non-profile case there would have to be handled — and
    /// silently mishandled — at every site that walks the list. The same collision argument
    /// covers it: a clone's id is an absolute path, so neither literal can ever be one.
    static let limitsID = "__limits__"

    var id: String {
        switch self {
        case .primary: Self.primaryID
        case let .clone(managed): managed.id
        }
    }
}
