import Foundation
import OSLog
import Photos
import SwiftUI

/// A photo from the user's local library. Thumbnails are fetched lazily
/// via PHImageManager (see `PhotoThumbnailView`). The `backupState` reflects
/// whether this asset has been uploaded to Vaultyx storage yet.
struct BackedUpPhoto: Identifiable, Hashable {
    let id: String               // PHAsset.localIdentifier
    let filename: String
    let sizeBytes: Int64
    let takenAt: Date
    var backupState: BackupState

    enum BackupState: Hashable {
        case backedUp
        case pending
        case uploading(Double)
        case failed
    }

    static func == (lhs: BackedUpPhoto, rhs: BackedUpPhoto) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
class PhotosViewModel: ObservableObject {
    @Published var backedUpPhotos: [BackedUpPhoto] = []
    @Published var backupInProgress = false
    @Published var backupProgress: Double = 0
    @Published var remainingCount = 0
    @Published var allBackedUp = false
    @Published var selectedPhoto: BackedUpPhoto?

    private weak var services: VaultServices?

    func configure(services: VaultServices) {
        self.services = services
    }

    /// Load recent photos only (limit 60 from newest first).
    /// This is called on the root PhotosView .task and is intentionally lightweight.
    /// In ScreenshotMode, injects synthetic seed photos instead.
    func loadRecentPhotos() async {
        if ScreenshotMode.seedData != nil {
            injectSeedPhotos()
            return
        }
        if ScreenshotMode.isActive { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        // PhotoKit's PHAsset.fetchAssets / enumerateObjects are synchronous
        // calls into Photos.sqlite via NSXPCStoreConnection. On main, they
        // hang the runloop and trip the iOS watchdog (bug type 228 / "UIKit-
        // runloop timeout"). Move all PhotoKit work to a detached priority
        // task and only return the lightweight summary back to the main
        // actor for state mutation.
        let summaries: [PhotoSummary] = await Task.detached(priority: .userInitiated) {
            Self.fetchRecentPhotoSummaries(limit: 60)
        }.value
        dlog("loadRecentPhotos: fetched \(summaries.count) photo summaries", category: "photos", level: .info)

        services?.photoBackup.refresh()
        let backedUp = services?.photoBackup.backedUpIdentifiers ?? []

        var photos: [BackedUpPhoto] = []
        photos.reserveCapacity(summaries.count)
        for s in summaries {
            let state: BackedUpPhoto.BackupState =
                backedUp.contains(s.localId) ? .backedUp : .pending
            photos.append(BackedUpPhoto(
                id: s.localId,
                filename: s.filename,
                sizeBytes: 0,
                takenAt: s.takenAt,
                backupState: state
            ))
        }
        backedUpPhotos = photos
        allBackedUp = !photos.isEmpty && photos.allSatisfy { $0.backupState == .backedUp }
    }

    /// Sendable summary of a PHAsset suitable for crossing isolation
    /// boundaries — the PHAsset object itself is bound to its fetch
    /// context, so we extract scalars eagerly while still off-main.
    private struct PhotoSummary: Sendable {
        let localId: String
        let filename: String
        let takenAt: Date
    }

    /// Fetch + summarize recent image assets. Pure PhotoKit work; runs off-main.
    /// `nonisolated` so it can be called from a `Task.detached` block — without
    /// this, the @MainActor on the enclosing class would prevent off-main invocation.
    nonisolated private static func fetchRecentPhotoSummaries(limit: Int) -> [PhotoSummary] {
        // Show recent media. No mediaType filter to preserve Live Photos and iCloud-shared content.
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: opts)
        var collected: [PHAsset] = []
        result.enumerateObjects { a, _, _ in collected.append(a) }
        return collected.map { asset in
            PhotoSummary(
                localId: asset.localIdentifier,
                filename: (asset.value(forKey: "filename") as? String) ?? "IMG.HEIC",
                takenAt: asset.creationDate ?? .distantPast)
        }
    }

    /// Logger for the photo backup pipeline. Visible in Console.app on
    /// TestFlight builds with subsystem `com.katafract.vault.photos`.
    private let logger = Logger(subsystem: "com.katafract.vault.photos", category: "backup")

    /// Convention: photos back up to the vault root. When per-album folder
    /// targeting lands (separate WP), this becomes a parameter on
    /// `enqueuePhoto(asset:targetFolderId:)`.
    private static let rootFolderId = "root"

    func startBackupNow() {
        guard let services = self.services else {
            logger.error("startBackupNow called before VaultServices was wired")
            dlog("startBackupNow called before VaultServices was wired", category: "photos", level: .error)
            return
        }
        guard !backupInProgress else { return }

        // Skip both the already-uploaded and the user-excluded (deleted-from-
        // backup) sets. Without the exclusion check, tapping Backup Now after
        // the user has explicitly removed a photo would silently re-upload it.
        let pending = backedUpPhotos.filter {
            $0.backupState != .backedUp
                && !services.photoBackup.isExcludedFromBackup($0.id)
        }
        guard !pending.isEmpty else {
            allBackedUp = true
            return
        }

        backupInProgress = true
        backupProgress = 0
        remainingCount = pending.count

        let pendingIDs = pending.map(\.id)
        Task { [weak self] in
            await self?.runBackupBatch(pendingIDs: pendingIDs, services: services)
        }
    }

    /// Iterate pending photos, encrypt + queue each via syncEngine.importFile,
    /// promote per-asset state in `backedUpPhotos`. Failures don't abort the
    /// batch — they mark that photo `.failed` and continue.
    private func runBackupBatch(pendingIDs: [String], services: VaultServices) async {
        defer {
            backupInProgress = false
            backupProgress = 1.0
            remainingCount = 0
            services.photoBackup.refresh()
            allBackedUp = backedUpPhotos.allSatisfy { $0.backupState == .backedUp }
        }

        let total = pendingIDs.count
        var done = 0

        for assetID in pendingIDs {
            done += 1
            updateAssetState(id: assetID, to: .uploading(0.0))

            // Resolve PHAsset by localIdentifier.
            let fetchOpts = PHFetchOptions()
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: fetchOpts)
            guard let asset = assets.firstObject else {
                logger.error("PHAsset \(assetID, privacy: .public) not found in library")
                dlog("PHAsset not found for \(assetID)", category: "photos", level: .error)
                updateAssetState(id: assetID, to: .failed)
                advanceProgress(done: done, total: total)
                continue
            }

            do {
                let fileId = try await services.photoBackup.enqueueAsset(asset)
                updateAssetState(id: assetID, to: .backedUp)
                logger.info("photo backed up: \(assetID, privacy: .public) → \(fileId, privacy: .public)")
            } catch {
                logger.error("photo backup failed for \(assetID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                dlog("photo backup failed for \(assetID): \(error.localizedDescription)", category: "photos", level: .error)
                updateAssetState(id: assetID, to: .failed)
            }

            advanceProgress(done: done, total: total)
        }
    }

    private func updateAssetState(id: String, to newState: BackedUpPhoto.BackupState) {
        if let idx = backedUpPhotos.firstIndex(where: { $0.id == id }) {
            backedUpPhotos[idx].backupState = newState
        }
    }

    /// Remove a backed-up photo from the vault. Soft-deletes the encrypted
    /// file on the server, deletes the matching `BackedUpAsset` record, and
    /// flips the row back to `.pending` so the grid badge updates.
    /// The local PHAsset is not touched — only the encrypted vault copy.
    func removeFromBackup(_ photo: BackedUpPhoto) {
        guard let services else {
            logger.error("removeFromBackup called before VaultServices was wired")
            return
        }
        let assetId = photo.id
        Task { @MainActor in
            await services.photoBackup.removeBackup(assetIdentifier: assetId, apiClient: services.apiClient)
            updateAssetState(id: assetId, to: .pending)
            allBackedUp = !backedUpPhotos.isEmpty && backedUpPhotos.allSatisfy { $0.backupState == .backedUp }
        }
    }

    private func advanceProgress(done: Int, total: Int) {
        backupProgress = total > 0 ? Double(done) / Double(total) : 1.0
        remainingCount = max(0, total - done)
    }

    /// Injects synthetic seed photos for XCUITest screenshot runs.
    private func injectSeedPhotos() {
        let seedPhotos = [
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Sunset at Acadia.heic",
                sizeBytes: 3_200_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 2),
                backupState: .backedUp
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Coffee Morning.jpeg",
                sizeBytes: 1_400_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 3),
                backupState: .backedUp
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Garden Update.heic",
                sizeBytes: 4_100_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 5),
                backupState: .backedUp
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Birthday Cake.jpeg",
                sizeBytes: 2_300_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 7),
                backupState: .pending
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Mountain Trek.heic",
                sizeBytes: 5_600_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 9),
                backupState: .uploading(0.35)
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Beach Day.jpeg",
                sizeBytes: 3_800_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 12),
                backupState: .backedUp
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Concert Night.heic",
                sizeBytes: 6_200_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 15),
                backupState: .backedUp
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Restaurant Plating.jpeg",
                sizeBytes: 2_900_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 18),
                backupState: .failed
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Autumn Leaves.heic",
                sizeBytes: 4_700_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 21),
                backupState: .backedUp
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Hiking Summit.jpeg",
                sizeBytes: 3_500_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 25),
                backupState: .pending
            ),
        ]
        backedUpPhotos = seedPhotos
        allBackedUp = seedPhotos.allSatisfy { $0.backupState == .backedUp }
    }
}

