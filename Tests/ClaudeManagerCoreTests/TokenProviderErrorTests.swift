import Foundation
import Testing
@testable import ClaudeManagerCore

/// The one classification of a token-read failure — what the user can do about it, whether the
/// binding holds a login at all, and whether it proves the safeStorage key decrypts. Four view
/// tables and the merge rule paint from these, so they are asserted here rather than re-derived
/// (and left to drift) at each surface.
struct TokenProviderErrorTests {
    @Test
    func onlyAMissingLoginOffersASignIn() {
        #expect(TokenProviderError.signedOut.remedy == .signIn)
        #expect(TokenProviderError.noTokenCache.remedy == .signIn)
        // An access refusal is fixable, but not by signing in.
        #expect(TokenProviderError.keychainUnavailable(.interactionNotAllowed).remedy == .authorizeKeychain)
        // Nothing below has a remedy anyone could name in a word — naming one anyway sends the
        // user to do the one thing that cannot help.
        #expect(TokenProviderError.keychainUnavailable(.notFound).remedy == .none)
        #expect(TokenProviderError.keychainUnavailable(.unexpected(-25300)).remedy == .none)
        #expect(TokenProviderError.decryptFailed(.decryptFailed).remedy == .none)
        #expect(TokenProviderError.malformedCache.remedy == .none)
        #expect(TokenProviderError.noUsableEntry.remedy == .none)
        #expect(TokenProviderError.configUnreadable.remedy == .none)
    }

    @Test
    func onlyAnAbsentLoginMeansNotSignedIn() {
        #expect(TokenProviderError.signedOut.meansNotSignedIn)
        #expect(TokenProviderError.noTokenCache.meansNotSignedIn)
        // A keychain we couldn't read leaves the login intact — which is why a binding failing this
        // way keeps the account fan-out `UsageService.merge` would otherwise collapse.
        #expect(!TokenProviderError.keychainUnavailable(.interactionNotAllowed).meansNotSignedIn)
        #expect(!TokenProviderError.decryptFailed(.decryptFailed).meansNotSignedIn)
        #expect(!TokenProviderError.malformedCache.meansNotSignedIn)
        #expect(!TokenProviderError.noUsableEntry.meansNotSignedIn)
        #expect(!TokenProviderError.configUnreadable.meansNotSignedIn)
    }

    @Test
    func onlyAParsedCacheProvesTheKeyDecrypts() {
        // Both of these got as far as valid JSON, so the key is right whatever came next.
        #expect(TokenProviderError.signedOut.provesKeyDecrypts)
        #expect(TokenProviderError.noUsableEntry.provesKeyDecrypts)
        // `.malformedCache` is the opposite: plaintext that isn't a JSON object is a wrong-key
        // symptom, so it must not veto the fleet's key recovery.
        #expect(!TokenProviderError.malformedCache.provesKeyDecrypts)
        #expect(!TokenProviderError.decryptFailed(.decryptFailed).provesKeyDecrypts)
        // These never reached a decrypt at all.
        #expect(!TokenProviderError.noTokenCache.provesKeyDecrypts)
        #expect(!TokenProviderError.configUnreadable.provesKeyDecrypts)
        #expect(!TokenProviderError.keychainUnavailable(.interactionNotAllowed).provesKeyDecrypts)
    }
}
