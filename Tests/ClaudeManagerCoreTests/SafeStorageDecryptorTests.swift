import CommonCrypto
import Foundation
import Testing
@testable import ClaudeManagerCore

struct SafeStorageDecryptorTests {
    private let decryptor = SafeStorageDecryptor()

    /// A known 16-byte AES key derived from a fixed password (also what the provider tests
    /// use), so a fixture never carries a real secret.
    private static let key = SafeStorageDecryptor.deriveKey(password: Data("unit-test-password".utf8))!

    /// Build a real `v10` safeStorage blob from plaintext under `key` — the same scheme the
    /// Desktop app writes, so decrypt is exercised end-to-end without a captured token.
    static func makeV10Blob(_ plaintext: Data, key: Data) -> Data {
        let ciphertext = SafeStorageDecryptor.crypt(
            kCCEncrypt, plaintext, key: key, iv: SafeStorageDecryptor.iv
        )!
        return Data(CoreConstants.safeStorageBlobPrefix.utf8) + ciphertext
    }

    @Test
    func deriveKeyIsDeterministicAnd16Bytes() {
        let a = SafeStorageDecryptor.deriveKey(password: Data("pw".utf8))
        let b = SafeStorageDecryptor.deriveKey(password: Data("pw".utf8))
        #expect(a != nil)
        #expect(a?.count == 16)
        #expect(a == b)
        #expect(SafeStorageDecryptor.deriveKey(password: Data("other".utf8)) != a)
    }

    @Test
    func roundTripsPlaintextThroughV10() throws {
        let secret = Data("the-quick-brown-fox-jumps-over-the-lazy-dog".utf8)
        let blob = Self.makeV10Blob(secret, key: Self.key)
        let result = decryptor.decrypt(v10Blob: blob, key: Self.key)
        #expect(try result.get() == secret)
    }

    @Test
    func roundTripsAcrossBlockBoundaryLengths() throws {
        // Exercise PKCS7 across lengths just under/at/over a block.
        for length in [0, 1, 15, 16, 17, 31, 32, 100] {
            let secret = Data((0 ..< length).map { UInt8($0 % 256) })
            let blob = Self.makeV10Blob(secret, key: Self.key)
            #expect(try decryptor.decrypt(v10Blob: blob, key: Self.key).get() == secret)
        }
    }

    @Test
    func rejectsNonV10Prefix() {
        let blob = Data("v11".utf8) + Data(count: 16)
        #expect(decryptor.decrypt(v10Blob: blob, key: Self.key) == .failure(.notV10))
    }

    @Test
    func rejectsNonBlockAlignedCiphertext() {
        let blob = Data(CoreConstants.safeStorageBlobPrefix.utf8) + Data(count: 20) // 20 % 16 != 0
        #expect(decryptor.decrypt(v10Blob: blob, key: Self.key) == .failure(.notBlockAligned))
    }

    @Test
    func wrongKeyNeverRecoversPlaintextAndNeverCrashes() throws {
        // AES-CBC + PKCS7 with a wrong key usually fails on padding (~255/256), but ~1/256
        // the last byte is a coincidentally-valid pad length and CCCrypt returns garbage.
        // The security invariant is only that the *original* plaintext is never recovered —
        // and that neither outcome crashes. (The provider then rejects garbage as non-JSON.)
        let secret = Data("payload".utf8)
        let blob = Self.makeV10Blob(secret, key: Self.key)
        let wrongKey = try #require(SafeStorageDecryptor.deriveKey(password: Data("wrong".utf8)))
        if case let .success(plain) = decryptor.decrypt(v10Blob: blob, key: wrongKey) {
            #expect(plain != secret)
        }
    }
}
