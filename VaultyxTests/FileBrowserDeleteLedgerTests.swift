import XCTest
import SwiftData
@testable import Vaultyx

/// Regression coverage for issue #212 (optimistic delete/undo race + ledger
/// drift). `FileBrowserViewModel.deleteItem` isn't unit-testable end-to-end
/// here — like `PhotoBackupManager` (#209) and the recovery-kit Keychain
/// path (#206), it depends on `VaultAPIClient`, a concrete class with no
/// protocol seam to inject a delayed/failing mock, so exercising the actual
/// delayed-delete-plus-immediate-Undo race or a simulated server failure
/// would require a real backend.
///
/// What IS directly testable, and is exactly the mechanism the #212 fix's
/// failure-path rollback depends on, is `BackedUpAssetSnapshot`: the fix
/// snapshots every field of a `BackedUpAsset` row before optimistically
/// deleting it, then reconstructs an equivalent row from that snapshot if
/// the server delete fails. If this round trip ever silently dropped or
/// mutated a field, the ledger-drift bug #212 exists to fix would resurface
/// under a different name.
@MainActor
final class FileBrowserDeleteLedgerTests: XCTestCase {

    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([BackedUpAsset.self])
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    func testSnapshotRoundTripPreservesAllFields() throws {
        let context = try makeInMemoryContext()
        let original = BackedUpAsset(
            assetIdentifier: "asset-round-trip",
            fileId: "file-1",
            folderId: "folder-1",
            backedUpAt: Date(timeIntervalSince1970: 1_700_000_000),
            sizeBytes: 123_456,
            originalFilename: "IMG_0001.HEIC",
            removalPendingSince: nil)
        context.insert(original)
        try context.save()

        let snapshot = FileBrowserViewModel.BackedUpAssetSnapshot(original)
        context.delete(original)
        try context.save()

        // Row is genuinely gone -- this is the state a failed server delete
        // would otherwise have left permanently, before the #212 fix.
        let afterDelete = try context.fetch(FetchDescriptor<BackedUpAsset>())
        XCTAssertTrue(afterDelete.isEmpty)

        let restored = snapshot.makeRow()
        context.insert(restored)
        try context.save()

        let afterRestore = try context.fetch(FetchDescriptor<BackedUpAsset>())
        XCTAssertEqual(afterRestore.count, 1)
        let row = try XCTUnwrap(afterRestore.first)
        XCTAssertEqual(row.assetIdentifier, "asset-round-trip")
        XCTAssertEqual(row.fileId, "file-1")
        XCTAssertEqual(row.folderId, "folder-1")
        XCTAssertEqual(row.backedUpAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(row.sizeBytes, 123_456)
        XCTAssertEqual(row.originalFilename, "IMG_0001.HEIC")
        XCTAssertNil(row.removalPendingSince)
    }

    /// A row can be mid-removal (issue #209's `removalPendingSince` state)
    /// at the moment a file delete is also attempted on it. The snapshot
    /// must carry that field through too, not just the "steady state"
    /// fields — otherwise restoring after a failed delete would silently
    /// clear an in-flight #209 removal-retry marker.
    func testSnapshotRoundTripPreservesRemovalPendingSince() throws {
        let context = try makeInMemoryContext()
        let pendingSince = Date(timeIntervalSince1970: 1_700_000_500)
        let original = BackedUpAsset(
            assetIdentifier: "asset-pending",
            fileId: "file-2",
            folderId: "folder-1",
            removalPendingSince: pendingSince)
        context.insert(original)
        try context.save()

        let snapshot = FileBrowserViewModel.BackedUpAssetSnapshot(original)
        let restored = snapshot.makeRow()

        XCTAssertEqual(restored.removalPendingSince, pendingSince)
    }

    /// The unique `assetIdentifier` constraint means restoring a snapshot
    /// must produce a row indistinguishable from the original for the
    /// purposes of every other query in the codebase that filters by
    /// `fileId` (both the delete path itself and `PhotoBackupManager`'s
    /// #209 retry query key off it) -- a snapshot that silently drops or
    /// swaps `fileId` would make the restored row invisible to those
    /// queries even though the row itself exists.
    func testRestoredRowIsFindableByFileId() throws {
        let context = try makeInMemoryContext()
        let original = BackedUpAsset(assetIdentifier: "asset-findable", fileId: "file-3", folderId: "root")
        context.insert(original)
        try context.save()

        let snapshot = FileBrowserViewModel.BackedUpAssetSnapshot(original)
        context.delete(original)
        try context.save()

        context.insert(snapshot.makeRow())
        try context.save()

        let rows = try context.fetch(FetchDescriptor<BackedUpAsset>())
        XCTAssertTrue(rows.contains { $0.fileId == "file-3" })
    }
}
