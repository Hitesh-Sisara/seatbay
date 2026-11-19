import XCTest
@testable import Seatbay

final class BackupCryptoTests: XCTestCase {
    func testRoundTrip() throws {
        let plain = Data((0..<10_000).map { UInt8($0 % 251) })
        let sealed = try BackupCrypto.encrypt(plain, passphrase: "correct horse battery staple")
        XCTAssertTrue(sealed.starts(with: BackupCrypto.magic))
        XCTAssertNotEqual(sealed.dropFirst(25), plain)
        XCTAssertEqual(try BackupCrypto.decrypt(sealed, passphrase: "correct horse battery staple"), plain)
    }

    func testWrongPassphraseAndTamperingFail() throws {
        let sealed = try BackupCrypto.encrypt(Data("secret".utf8), passphrase: "one")
        XCTAssertThrowsError(try BackupCrypto.decrypt(sealed, passphrase: "two"))
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01
        XCTAssertThrowsError(try BackupCrypto.decrypt(tampered, passphrase: "one"))
        XCTAssertThrowsError(try BackupCrypto.decrypt(Data("not a backup".utf8), passphrase: "one"))
        XCTAssertThrowsError(try BackupCrypto.encrypt(Data(), passphrase: ""))
    }

    func testPassphraseIsUnicodeNormalised() throws {
        let decomposed = "cafe\u{301}"   // e + combining accent
        let composed = "caf\u{e9}"
        let sealed = try BackupCrypto.encrypt(Data("x".utf8), passphrase: decomposed)
        XCTAssertEqual(try BackupCrypto.decrypt(sealed, passphrase: composed), Data("x".utf8))
    }

    func testEachFileGetsItsOwnSalt() throws {
        let a = try BackupCrypto.encrypt(Data("same".utf8), passphrase: "p")
        let b = try BackupCrypto.encrypt(Data("same".utf8), passphrase: "p")
        XCTAssertNotEqual(a, b)
    }
}
