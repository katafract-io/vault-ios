import XCTest
import SwiftData
@testable import Vaultyx

/// Regression coverage for issue #210: a vault store that fails to open must
/// never be silently moved/mutated by app code, and any failure must be
/// something the caller can observe (not swallowed into a "looks like a
/// normal empty vault" state). Exercises `VaultServices.attemptOpen`
/// directly against a scratch temp-directory URL — no real App Group
/// container, no need to instantiate the full (heavyweight: real API
/// client, background URLSession, etc.) `VaultServices` class.
final class VaultServicesBootstrapTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultServicesBootstrapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testOpeningAFreshStoreSucceeds() throws {
        let storeURL = tempDir.appendingPathComponent("fresh.sqlite")
        switch VaultServices.attemptOpen(overrideURL: storeURL) {
        case .success:
            break
        case .failure(let error):
            XCTFail("expected a fresh store to open cleanly, got \(error)")
        }
    }

    /// The actual defect this closes: previously, a failed open would move
    /// vault.sqlite/-wal/-shm into a Quarantine directory and silently open a
    /// fresh empty store at the original path. `attemptOpen` must do neither
    /// — it only ever tries to open what's there and reports success/failure,
    /// leaving the directory contents completely unchanged either way.
    func testFailedOpenNeverMutatesOrMovesAnyFiles() throws {
        let storeURL = tempDir.appendingPathComponent("corrupt.sqlite")
        // A corrupt/incompatible store: valid-looking file that isn't a real
        // SQLite database, which SwiftData/CoreData will fail to open.
        try Data("this is not a sqlite database".utf8).write(to: storeURL)

        let before = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()

        switch VaultServices.attemptOpen(overrideURL: storeURL) {
        case .success:
            XCTFail("expected opening a corrupt store to fail")
        case .failure:
            break // expected
        }

        let after = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()
        XCTAssertEqual(before, after, "a failed open must never move, quarantine, or otherwise touch any file in the store's directory")
        XCTAssertFalse(after.contains { $0.localizedCaseInsensitiveContains("quarantine") },
                       "no Quarantine directory should ever be created automatically")
    }

    /// A second attemptOpen call against the same still-corrupt file must
    /// keep failing consistently (no partial state from the first attempt
    /// makes the second one behave differently) — this is what
    /// `retryBootstrap()` relies on to tell the user the truth.
    func testRepeatedFailedOpenIsConsistent() throws {
        let storeURL = tempDir.appendingPathComponent("corrupt.sqlite")
        try Data("still not a database".utf8).write(to: storeURL)

        for attempt in 1...3 {
            switch VaultServices.attemptOpen(overrideURL: storeURL) {
            case .success:
                XCTFail("attempt \(attempt): expected failure against an unchanged corrupt file")
            case .failure:
                break
            }
        }
    }
}
