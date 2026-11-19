import CommonCrypto
import CryptoKit
import Foundation

/// Encrypts backups before they leave this Mac.
///
/// Format: "MCBK1" | salt (16 bytes) | PBKDF2-HMAC-SHA256 rounds (UInt32, big-endian) | AES-256-GCM
/// combined box (12-byte random nonce, ciphertext, 16-byte tag). The header is authenticated as
/// associated data. The key comes from the user's passphrase (Unicode NFC), so a backup can be
/// decrypted on another Mac with the same passphrase. The rounds are stored per file, so files made
/// with fewer rounds by earlier versions still open. ("MCBK" dates from the app's earlier name.)
enum BackupCrypto {
    static let magic = Data("MCBK1".utf8)
    static let rounds: UInt32 = 600_000   // OWASP's 2023+ recommendation for PBKDF2-HMAC-SHA256

    enum CryptoError: LocalizedError {
        case noPassphrase, notABackup, wrongPassphrase, noRandomness

        var errorDescription: String? {
            switch self {
            case .noPassphrase: return "Set an encryption passphrase for S3 backups first."
            case .notABackup: return "This file isn't a Seatbay backup."
            case .wrongPassphrase: return "The backup could not be decrypted. Check the passphrase."
            case .noRandomness: return "macOS couldn't provide random bytes for encryption. Nothing was uploaded."
            }
        }
    }

    static func encrypt(_ plaintext: Data, passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else { throw CryptoError.noPassphrase }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CryptoError.noRandomness }
        var header = magic + salt
        withUnsafeBytes(of: rounds.bigEndian) { header.append(contentsOf: $0) }
        let key = try deriveKey(passphrase: passphrase.precomposedStringWithCanonicalMapping, salt: salt, rounds: rounds)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = box.combined else { throw CryptoError.notABackup }
        return header + combined
    }

    static func decrypt(_ blob: Data, passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else { throw CryptoError.noPassphrase }
        let headerLength = magic.count + 16 + 4
        guard blob.count > headerLength + 28, blob.prefix(magic.count) == magic else { throw CryptoError.notABackup }
        let header = blob.prefix(headerLength)
        let salt = blob.subdata(in: magic.count..<(magic.count + 16))
        let roundsData = blob.subdata(in: (magic.count + 16)..<headerLength)
        let storedRounds = roundsData.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard storedRounds >= 10_000, storedRounds <= 10_000_000 else { throw CryptoError.notABackup }
        guard let box = try? AES.GCM.SealedBox(combined: blob.subdata(in: headerLength..<blob.count)) else {
            throw CryptoError.notABackup
        }
        // NFC first; the passphrase exactly as typed covers files from versions that didn't normalise it.
        var candidates = [passphrase.precomposedStringWithCanonicalMapping]
        if passphrase != candidates[0] { candidates.append(passphrase) }
        for candidate in candidates {
            let key = try deriveKey(passphrase: candidate, salt: salt, rounds: storedRounds)
            if let plain = try? AES.GCM.open(box, using: key, authenticating: header) { return plain }
        }
        throw CryptoError.wrongPassphrase
    }

    private static func deriveKey(passphrase: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        let password = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { passwordBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     passwordBytes.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                     password.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw CryptoError.notABackup }
        return SymmetricKey(data: derived)
    }
}
