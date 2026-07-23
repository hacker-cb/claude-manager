import Foundation

/// The identity of one Claude account — the entity that *owns* plan usage. A 5h/weekly
/// limit belongs to the subscription, not to any surface, so many Desktop profiles (and,
/// later, CLI instances) can bind to the same `AccountIdentity`; usage is fetched and
/// cached once per `uuid`, keyed by it everywhere.
///
/// `uuid` is the account UUID resolved from the decrypted token's organization/account
/// (the source of truth); `config.json`'s `lastKnownAccountUuid` is only a fast hint used
/// before that reconciliation. The profile-oriented fields are filled from `/oauth/profile`
/// (cached long) and are all optional so a snapshot with just a `uuid` is still valid.
public struct AccountIdentity: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Account UUID — the dedup / cache key.
    public var uuid: String
    public var email: String?
    public var displayName: String?
    public var organizationUuid: String?
    /// e.g. `max`, `pro`, `team`, `enterprise` — gates surfaces like the Sonnet/scoped bar.
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public init(
        uuid: String,
        email: String? = nil,
        displayName: String? = nil,
        organizationUuid: String? = nil,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil
    ) {
        self.uuid = uuid
        self.email = email
        self.displayName = displayName
        self.organizationUuid = organizationUuid
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    public var id: String {
        uuid
    }

    /// How to name this account to a person: the email, else the display name, else nothing.
    /// Never the uuid — that's a storage key, not something worth showing. Nil until `/profile`
    /// has answered for the account's token, so callers must treat it as optional rather than
    /// rendering an empty slot.
    public var accountLabel: String? {
        let label = email ?? displayName
        return (label?.isEmpty ?? true) ? nil : label
    }

    /// Whether this account should show the per-model (scoped) weekly bar — only Max and
    /// Team plans have a scoped limit distinct from the weekly-all limit (mirrors the CLI's
    /// `Settings/Usage.tsx` rule; nil/unknown plan shows it, matching that source).
    public var showsScopedWeeklyLimit: Bool {
        switch subscriptionType?.lowercased() {
        case "max", "team", nil: true
        default: false
        }
    }
}
