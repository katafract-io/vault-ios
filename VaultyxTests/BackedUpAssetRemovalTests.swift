import XCTest
import SwiftData
@testable import Vaultyx

/// Regression coverage for issue #209's persisted state machine: a photo
/// removal marks `BackedUpAsset.removalPendingSince` and must NOT delete the
/// row until the remote soft-delete is confirmed. `PhotoBackupManager`
/// itself isn't unit-testable in isolation here — `VaultAPIClient` is a
/// concrete class with no protocol seam to inject a failing/succeeding
/// mock, so exercising the actual network-failure branch of `removeBackup`
/// would require a real backend. What IS directly testable, and is exactly
/// the mechanism `retryPendingRemovals()` depends on, is the SwiftData
/// predicate query over the new optional field — these tests prove that
/// query behaves correctly against `removalPendingSince: Date?` (SwiftData
/// predicates over Optional comparisons have had real gotchas historically,
/// so this is not a throwaway assertion).
@MainActor
final class BackedUpAssetRemovalTests: XCTestCase {

    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([BackedUpAsset.self])
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    func testFreshRowHasNoRemovalPending() throws {
        let context = try makeInMemoryContext()
        let row = BackedUpAsset(assetIdentifier: "a1", fileId: "f1", folderId: "root")
        context.insert(row)
        try context.save()

        XCTAssertNil(row.removalPendingSince)
    }

    func testPendingRemovalPredicateFindsOnlyMarkedRows() throws {
        let context = try makeInMemoryContext()
        let pending = BackedUpAsset(assetIdentifier: "pending-1", fileId: "f1", folderId: "root")
        pending.removalPendingSince = Date()
        let notPending = BackedUpAsset(assetIdentifier: "not-pending-1", fileId: "f2", folderId: "root")
        context.insert(pending)
        context.insert(notPending)
        try context.save()

        let descriptor = FetchDescriptor<BackedUpAsset>(
            predicate: #Predicate { $0.removalPendingSince != nil })
        let results = try context.fetch(descriptor)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.assetIdentifier, "pending-1")
    }

    /// Marking a row pending must not lose the data a retry needs (fileId in
    /// particular — `retryPendingRemovals` re-reads it to call
    /// `softDeleteFile(fileId:)` again).
    func testMarkingPendingPreservesOtherFields() throws {
        let context = try makeInMemoryContext()
        let row = BackedUpAsset(assetIdentifier: "a1", fileId: "file-123", folderId: "folder-abc", originalFilename: "IMG_0001.jpg")
        context.insert(row)
        try context.save()

        row.removalPendingSince = Date()
        try context.save()

        XCTAssertEqual(row.fileId, "file-123")
        XCTAssertEqual(row.folderId, "folder-abc")
        XCTAssertEqual(row.originalFilename, "IMG_0001.jpg")
    }

    /// The retry helper's re-fetch-by-identifier pattern: after marking a row
    /// pending, fetching by `assetIdentifier` (what `removeBackup` does on
    /// every call, including retries) must still find the same row rather
    /// than, say, a stale duplicate.
    func testRefetchByIdentifierFindsTheSamePendingRow() throws {
        let context = try makeInMemoryContext()
        let row = BackedUpAsset(assetIdentifier: "a1", fileId: "f1", folderId: "root")
        row.removalPendingSince = Date()
        context.insert(row)
        try context.save()

        let descriptor = FetchDescriptor<BackedUpAsset>(
            predicate: #Predicate<BackedUpAsset> { $0.assetIdentifier == "a1" })
        let results = try context.fetch(descriptor)

        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(results.first?.removalPendingSince)
    }
}
