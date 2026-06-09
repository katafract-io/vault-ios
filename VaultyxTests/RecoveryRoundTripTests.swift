import XCTest
import Foundation
import CryptoKit
@testable import Vaultyx

/// Golden recovery round-trip — the test whose absence let the data-loss bug
/// ship. If onboarding ever again shows a phrase that doesn't encode the real
/// master key, `testEncryptWipeRestoreDecrypt` fails.
final class RecoveryRoundTripTests: XCTestCase {

    func testGoldenRecoveryRoundTrip() throws {
        let master = SymmetricKey(size: .bits256)
        let words = RecoveryPhrase.phrase(for: master)
        XCTAssertEqual(words.count, 24)
        let restored = try RecoveryPhrase.key(from: words)
        XCTAssertEqual(
            master.withUnsafeBytes { Data($0) },
            restored.withUnsafeBytes { Data($0) },
            "Restored key must equal the original master key"
        )
    }

    func testEncryptWipeRestoreDecrypt() throws {
        let master = SymmetricKey(size: .bits256)
        let plaintext = Data("passport-scan-bytes".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: master)
        // Simulate a keychain wipe: only the printed phrase survives.
        let words = RecoveryPhrase.phrase(for: master)
        let restored = try RecoveryPhrase.key(from: words)
        let opened = try AES.GCM.open(sealed, using: restored)
        XCTAssertEqual(opened, plaintext, "A file sealed under the master key must open after phrase restore")
    }

    func testEncodeDecodeRoundTripRandom() throws {
        for _ in 0..<100 {
            var bytes = Data(count: 32)
            _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            let words = RecoveryPhrase.encode(entropy: bytes)
            XCTAssertEqual(try RecoveryPhrase.decode(words: words), bytes)
        }
    }

    func testChecksumCatchesSingleWordTypo() {
        let master = SymmetricKey(size: .bits256)
        var words = RecoveryPhrase.phrase(for: master)
        let original = words[0]
        words[0] = (original == "abandon") ? "ability" : "abandon"
        XCTAssertThrowsError(try RecoveryPhrase.key(from: words),
                             "A single-word substitution should fail the checksum")
    }
}
