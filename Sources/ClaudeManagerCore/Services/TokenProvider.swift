import CryptoKit
import Foundation

/// One account binding to resolve a token for — a Desktop profile (or the default account)
/// identified by `id`, whose `config.json` holds the encrypted `oauth:tokenCacheV2`.
public struct TokenBinding: Sendable, Equatable, Hashable {
    /// Stable binding id — a profile's launcher path, or `TokenBinding.defaultID`.
    public var id: String
    /// `<user-data-dir>/config.json`.
    public var configURL: URL

    public static let defaultID = "__default__"

    public init(id: String, configURL: URL) {
        self.id = id
        self.configURL = configURL
    }
}

/// A decrypted Desktop bearer token plus the account context needed to fetch usage. Note
/// the token field in `tokenCacheV2` is `token` (not `accessToken` as in the CLI), and
/// `expiresAt` is epoch **milliseconds**; both are normalized here.
public struct DesktopToken: Sendable, Equatable {
    /// The bearer token (`Authorization: Bearer <token>`).
    public var token: String
    /// Absolute expiry (from the cache's epoch-ms `expiresAt`).
    public var expiresAt: Date
    /// Scopes parsed from the cache's composite key (e.g. `user:inference`, `user:profile`).
    public var scopes: [String]
    /// Organization UUID from the composite key — the local grouping key before `/profile`.
    public var organizationUUID: String?
    public var subscriptionType: String?
    public var rateLimitTier: String?
    /// Which binding this came from (a profile id / default) — recorded as the sample source.
    public var bindingID: String

    public init(
        token: String,
        expiresAt: Date,
        scopes: [String],
        organizationUUID: String?,
        subscriptionType: String?,
        rateLimitTier: String?,
        bindingID: String
    ) {
        self.token = token
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.organizationUUID = organizationUUID
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.bindingID = bindingID
    }

    /// `sha256(token)[:16]` — a stable, non-secret identifier for *this token*. It is the local
    /// key for everything keyed per token: the identity/throttle scopes, and the account dedup in
    /// `AccountResolver` (identical token ⇒ provably the same account). A login switch changes the
    /// token and thus this value, so cached state for the old login is naturally invalidated.
    public var fingerprint: String {
        let hex = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// Expired (with a safety skew) — the poller skips the API call for an expired token.
    public func isExpired(now: Date = Date(), skew: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(skew) >= expiresAt
    }

    public var hasInferenceScope: Bool {
        scopes.contains(CoreConstants.oauthInferenceScope)
    }
}

/// Why a binding couldn't yield a usable token. Every case is non-fatal — mapped to a
/// login-needed / Doctor-note UI state, never a crash.
public enum TokenProviderError: Error, Equatable, Sendable {
    /// `config.json` missing or not JSON.
    case configUnreadable
    /// No `oauth:tokenCache*` key (account never signed in on this profile).
    case noTokenCache
    /// The safeStorage key couldn't be read — often the expected background outcome
    /// (`.interactionNotAllowed`): retry interactively, or serve stale.
    case keychainUnavailable(KeychainError)
    /// The blob decrypted-path failed (wrong key / corrupt / changed scheme).
    case decryptFailed(SafeStorageError)
    /// Decrypted, but not the expected token-cache JSON shape.
    case malformedCache
    /// No entry with the Claude Code client + inference/profile scope.
    case noUsableEntry
}

/// Resolves a `DesktopToken` for a binding. Behind a protocol so the resolver and tests can
/// swap the real safeStorage-backed provider for a stub.
public protocol TokenProvider: Sendable {
    /// `interactive: false` on the background poll path (fail fast on a locked/unauthorized
    /// keychain); `true` from an explicit user gesture (allow the one-time prompt).
    func token(for binding: TokenBinding, interactive: Bool) async -> Result<DesktopToken, TokenProviderError>
}
