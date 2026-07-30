import CryptoKit
import Foundation

/// One binding to resolve a token for — a Desktop profile (or the default profile) identified
/// by `id`, whose `config.json` holds the encrypted `oauth:tokenCacheV2`.
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
    /// Decrypted to an **empty** cache — the account signed out on this profile.
    ///
    /// Claude Desktop's logout does not remove `oauth:tokenCache*`; it re-encrypts the key with an
    /// empty object (`{}`, one 16-byte block), so the key is present, the blob decrypts, and the
    /// map is simply empty. Reported apart from `.noTokenCache` (the key was never written — a
    /// profile nobody has signed into, and the permanent state of the default binding for anyone
    /// who only uses launchers) because the two differ in tense, and apart from `.noUsableEntry`
    /// (entries exist, none of them ours) because only this one is fixed by signing in.
    case signedOut
    /// No entry with the Claude Code client + inference/profile scope.
    case noUsableEntry
}

public extension TokenProviderError {
    /// What the user can actually do about a failure — the **one** classification every surface
    /// paints from.
    ///
    /// Kept apart from the copy itself because the copy legitimately differs per surface (a 66pt
    /// sidebar cell, a spoken VoiceOver label, a full sentence in the pane) while the rule behind
    /// it must not: four tables each deciding on their own that `.interactionNotAllowed` means
    /// "authorize" is how a sidebar comes to say "Sign in" over a pane saying "source unavailable"
    /// for the same binding.
    enum Remedy: Sendable, Equatable {
        /// Open Claude on this profile and sign in.
        case signIn
        /// Grant Claude Manager access to Claude's keychain item.
        case authorizeKeychain
        /// Nothing we can name — a missing keychain item, an unreadable config, a cache holding no
        /// entry of ours. Naming one anyway sends the user to do something that cannot help.
        case none
    }

    var remedy: Remedy {
        switch self {
        case .signedOut, .noTokenCache: .signIn
        case .keychainUnavailable(.interactionNotAllowed): .authorizeKeychain
        case .configUnreadable, .keychainUnavailable, .decryptFailed, .malformedCache, .noUsableEntry: .none
        }
    }

    /// Whether the binding holds **no Claude login at all**, as opposed to a login we momentarily
    /// couldn't read.
    ///
    /// The distinction decides what may be carried forward from a previous pass: a locked keychain
    /// leaves the account intact, so its stored fan-out across sibling launchers is still true; a
    /// binding with no login is no longer part of any account's fan-out.
    var meansNotSignedIn: Bool {
        switch self {
        case .signedOut, .noTokenCache: true
        case .configUnreadable, .keychainUnavailable, .decryptFailed, .malformedCache, .noUsableEntry: false
        }
    }
}

/// Everything one pass can learn about a binding from its own `config.json`: the token when it
/// came out, and the account the file names either way.
///
/// A bare `Result` was the wrong shape here, and the cost was structural rather than cosmetic. A
/// binding whose blob would not decrypt fell out of its account entirely, because a *reason* is
/// all the failure arm could carry — yet the file we had just opened and parsed names the account
/// in plaintext, and a keychain that refuses us says nothing whatsoever about whether the profile
/// is still signed in. Returning both from one read is what lets a profile be "signed in,
/// momentarily unreadable" instead of "gone".
///
/// One read, not two: the hint sits in the same parsed root as the caches, so lifting it out here
/// costs nothing and removes any chance of the two answers coming from different reads of a file
/// that changed in between.
public struct BindingReading: Sendable, Equatable {
    /// The decrypted token, or why there isn't one.
    public var token: Result<DesktopToken, TokenProviderError>
    /// `lastKnownAccountUuid`, when the file carried a UUID-shaped one.
    ///
    /// Never authoritative — see `CoreConstants.desktopAccountHintKey` for the display/filing
    /// boundary this is allowed to live on, and `AccountResolver` for why it is still not a
    /// grouping key.
    public var hintedAccountUUID: String?

    public init(
        token: Result<DesktopToken, TokenProviderError>,
        hintedAccountUUID: String? = nil
    ) {
        self.token = token
        self.hintedAccountUUID = hintedAccountUUID
    }
}

/// Reads a binding's `config.json`. Behind a protocol so the resolver and tests can swap the real
/// safeStorage-backed provider for a stub.
public protocol TokenProvider: Sendable {
    /// `interactive: false` on the background poll path (fail fast on a locked/unauthorized
    /// keychain); `true` from an explicit user gesture (allow the one-time prompt).
    ///
    /// Never fails as a whole: an unreadable binding is a reading whose `token` is a failure, not
    /// the absence of a reading.
    func read(_ binding: TokenBinding, interactive: Bool) async -> BindingReading
}
