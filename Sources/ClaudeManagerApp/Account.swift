import ClaudeManagerCore

/// One row in every account list — the default account and each managed clone rendered as
/// peers. The default account is *not* a `ManagedProfile`: it has no launcher bundle, so it
/// offers no edit / remove / rebuild, only open / activate / stop.
enum Account: Identifiable {
    case primary(PrimaryAccountStatus)
    case clone(ManagedProfile)

    /// Selection id for the default-account row. A clone's id is its launcher `appPath`
    /// (an absolute filesystem path), so this literal can never collide with one.
    static let primaryID = "__default__"

    var id: String {
        switch self {
        case .primary: Self.primaryID
        case let .clone(managed): managed.id
        }
    }
}
