import CommonCrypto
import Foundation

/// Failure modes of Electron safeStorage decryption. All non-fatal — the provider maps
/// them to a "no usable token" state (login-needed / Doctor note), never a crash.
public enum SafeStorageError: Error, Equatable, Sendable {
    /// Blob doesn't begin with the `v10` marker (unknown/changed scheme).
    case notV10
    /// Ciphertext length isn't a whole number of AES blocks (truncated/corrupt).
    case notBlockAligned
    /// `CCCrypt` rejected the input (wrong key, bad PKCS7 padding, …).
    case decryptFailed
}

/// Decrypts Electron/Chrome-style macOS safeStorage blobs (`v10` + AES-128-CBC).
///
/// The key is derived from the "Claude Safe Storage" keychain password via PBKDF2; the
/// blob is `v10` + ciphertext, AES-128-CBC with a 16-space IV and PKCS7 padding. This is
/// a pure primitive over `CommonCrypto` (the only library with PBKDF2 + AES-CBC on Apple
/// platforms — CryptoKit has neither); it never reads the keychain or a file itself.
public struct SafeStorageDecryptor: Sendable {
    public init() {}

    /// The fixed IV Electron uses on macOS: 16 space bytes.
    static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    /// PBKDF2-HMAC-SHA1 key derivation with the safeStorage parameters
    /// (`CoreConstants.safeStorage*`). Returns nil only on an internal `CCKeyDerivationPBKDF`
    /// failure (effectively never for valid inputs).
    public static func deriveKey(password: Data) -> Data? {
        let salt = Data(CoreConstants.safeStoragePBKDFSalt.utf8)
        var derived = Data(count: CoreConstants.safeStorageKeyLength)
        let status = derived.withUnsafeMutableBytes { derivedPtr in
            salt.withUnsafeBytes { saltPtr in
                password.withUnsafeBytes { pwPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress?.assumingMemoryBound(to: CChar.self),
                        password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(CoreConstants.safeStoragePBKDFRounds),
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        CoreConstants.safeStorageKeyLength
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    /// Decrypt a raw (already base64-decoded) safeStorage blob to its plaintext bytes.
    public func decrypt(v10Blob blob: Data, key: Data) -> Result<Data, SafeStorageError> {
        let prefix = Data(CoreConstants.safeStorageBlobPrefix.utf8)
        guard blob.count > prefix.count, blob.prefix(prefix.count).elementsEqual(prefix) else {
            return .failure(.notV10)
        }
        let ciphertext = Data(blob.dropFirst(prefix.count))
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else {
            return .failure(.notBlockAligned)
        }
        guard let plain = Self.crypt(kCCDecrypt, ciphertext, key: key, iv: Self.iv) else {
            return .failure(.decryptFailed)
        }
        return .success(plain)
    }

    /// Symmetric AES-128-CBC + PKCS7 primitive. Exposed `internal` so tests can build a
    /// synthetic `v10` fixture (encrypt under a known key) without committing a real token.
    static func crypt(_ operation: Int, _ input: Data, key: Data, iv: Data) -> Data? {
        let capacity = input.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                iv.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            CCOperation(operation),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, input.count,
                            outPtr.baseAddress, capacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(moved ..< output.count)
        return output
    }
}
