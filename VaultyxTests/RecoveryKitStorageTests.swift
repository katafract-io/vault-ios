import XCTest
import CryptoKit
@testable import Vaultyx

/// Regression coverage for issue #206: storeWrappedKeyInKeychain must throw
/// (not silently report false-success) and recoveryKeyExists must correctly
/// answer whether a completion flag's backing artifact is actually present.
/// A full inject-a-SecItemAdd-failure test isn't feasible here -- there's no
/// DI seam over the Security framework calls themselves (same class of
/// constraint as VaultAPIClient elsewhere in this codebase) -- but the real
/// write/read-back round trip and the existence-check's both outcomes are
/// directly testable and are exactly what #206's fix depends on.
@MainActor
final class RecoveryKitStorageTests: XCTestCase {

    func testStoreWrappedKeySucceedsAndIsVerifiable() throws {
        let masterKey = SymmetricKey(size: .bits256)
        let sigilID = "recovery-kit-test-\(UUID().uuidString)"
        let vm = RecoveryKitViewModel(masterKey: masterKey, sigilID: sigilID)
        vm.phrase = (0..<24).map { "word\($0)" }

        try vm.storeWrappedKeyInKeychain()

        XCTAssertTrue(RecoveryKitViewModel.recoveryKeyExists(sigilID: sigilID),
                      "a successful store must be immediately verifiable via recoveryKeyExists")
    }

    func testRecoveryKeyExistsIsFalseForNeverWrittenSigilID() {
        XCTAssertFalse(
            RecoveryKitViewModel.recoveryKeyExists(sigilID: "definitely-never-written-\(UUID().uuidString)"),
            "a sigilID nothing was ever stored under must not report as existing")
    }

    /// Storing twice for the same sigilID must not fail or leave two
    /// conflicting records (storeWrappedKeyInKeychain deletes any existing
    /// item before adding) -- this is what makes a Retry after a failure
    /// safe to just call again.
    func testStoringTwiceForSameSigilIDSucceedsBothTimes() throws {
        let masterKey = SymmetricKey(size: .bits256)
        let sigilID = "recovery-kit-retry-test-\(UUID().uuidString)"
        let vm = RecoveryKitViewModel(masterKey: masterKey, sigilID: sigilID)
        vm.phrase = (0..<24).map { "word\($0)" }

        try vm.storeWrappedKeyInKeychain()
        try vm.storeWrappedKeyInKeychain()

        XCTAssertTrue(RecoveryKitViewModel.recoveryKeyExists(sigilID: sigilID))
    }
}
