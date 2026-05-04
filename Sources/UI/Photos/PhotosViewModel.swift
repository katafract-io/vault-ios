import Foundation
import OSLog
import Photos
import SwiftUI

struct AlbumItem: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
    var isEnabled: Bool
    var backedUpCount: Int = 0
}

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
    @Published var albums: [AlbumItem] = []
    @Published var backedUpPhotos: [BackedUpPhoto] = []
    @Published var backupInProgress = false
    @Published var backupProgress: Double = 0
    @Published var remainingCount = 0
    @Published var allBackedUp = false
    @Published var selectedPhoto: BackedUpPhoto?
    @Published var isLoadingAlbums = false

    var totalBackedUpCount: Int {
        backedUpPhotos.filter { $0.backupState == .backedUp }.count
    }
    var totalBackedUpBytes: Int64 {
        backedUpPhotos.filter { $0.backupState == .backedUp }.reduce(0) { $0 + $1.sizeBytes }
    }

    private weak var services: VaultServices?

    /// UserDefaults key holding the array of enabled album localIdentifiers.
    /// Presence of the key (even with an empty array) means the user has
    /// interacted with toggles at least once — on subsequent loads we use
    /// their stored set verbatim. Absence means first-run, and we default to
    /// Recents-only.
    private let enabledAlbumsKey = "vaultyx.photos.enabled_albums"

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

        // Honor the user's album selection. The grid is a *preview of what
        // will be backed up* — if the user disabled every album (including
        // Recents, which is iOS's "all photos" view), they expect an empty
        // grid. Reading the persisted set with `defaults.object(forKey:)`
        // lets us distinguish "never set" (first launch → fall back to a
        // recent-images preview) from "deliberately empty" (show nothing).
        let defaults = UserDefaults.standard
        let hasPersisted = defaults.object(forKey: enabledAlbumsKey) != nil
        let enabledIds = Set(defaults.stringArray(forKey: enabledAlbumsKey) ?? [])

        dlog("loadRecentPhotos: hasPersisted=\(hasPersisted) enabledIds.count=\(enabledIds.count) ids=\(Array(enabledIds).map { String($0.prefix(12)) })", category: "photos", level: .info)

        if hasPersisted && enabledIds.isEmpty {
            dlog("loadRecentPhotos: empty selection, showing empty grid", category: "photos", level: .info)
            backedUpPhotos = []
            allBackedUp = false
            return
        }

        // PhotoKit's PHAsset.fetchAssets / enumerateObjects are synchronous
        // calls into Photos.sqlite via NSXPCStoreConnection. On main, they
        // hang the runloop and trip the iOS watchdog (bug type 228 / "UIKit-
        // runloop timeout"). Move all PhotoKit work to a detached priority
        // task and only return the lightweight summary back to the main
        // actor for state mutation.
        let summaries: [PhotoSummary] = await Task.detached(priority: .userInitiated) {
            Self.fetchPhotoSummaries(hasPersisted: hasPersisted, enabledIds: enabledIds, limit: 60)
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

    /// Fetch + summarize image assets. Pure PhotoKit work; runs off-main.
    /// `hasPersisted` distinguishes first-launch (recent-images preview)
    /// from a deliberate album selection. `nonisolated` so it can be called
    /// from a `Task.detached` block — without this, the @MainActor on the
    /// enclosing class would prevent off-main invocation.
    nonisolated private static func fetchPhotoSummaries(
        hasPersisted: Bool, enabledIds: Set<String>, limit: Int
    ) -> [PhotoSummary] {
        let assets: [PHAsset]
        if hasPersisted {
            assets = fetchAssets(fromAlbums: enabledIds, limit: limit)
        } else {
            // First-launch preview, no album selection yet — show recent media.
            // No mediaType filter (see fetchAssets above).
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.fetchLimit = limit
            let result = PHAsset.fetchAssets(with: opts)
            var collected: [PHAsset] = []
            result.enumerateObjects { a, _, _ in collected.append(a) }
            assets = collected
        }
        return assets.map { asset in
            PhotoSummary(
                localId: asset.localIdentifier,
                filename: (asset.value(forKey: "filename") as? String) ?? "IMG.HEIC",
                takenAt: asset.creationDate ?? .distantPast)
        }
    }

    /// Fetch image assets belonging to any of the given album local-ids.
    /// Deduplicates across albums, sorts newest-first, caps at `limit`.
    /// MUST be called off-main — see `fetchPhotoSummaries`.
    nonisolated private static func fetchAssets(fromAlbums albumIds: Set<String>, limit: Int) -> [PHAsset] {
        let idArray = Array(albumIds)
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: idArray, options: nil)
        dlog("fetchAssets: requested \(idArray.count) album id(s), resolved \(collections.count) collection(s)", category: "photos", level: .info)
        // No mediaType predicate — Vaultyx backs up whatever the user has in
        // an album. Filtering on PHAssetMediaType.image excluded videos
        // (and some Live Photos / iCloud-shared content) and produced the
        // empty-grid + silent-backup symptom Tek hit on build 520.
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        var seen = Set<String>()
        var collected: [PHAsset] = []
        collections.enumerateObjects { collection, _, _ in
            let result = PHAsset.fetchAssets(in: collection, options: opts)
            dlog("fetchAssets: collection '\(collection.localizedTitle ?? "?")' (\(String(collection.localIdentifier.prefix(12)))) → \(result.count) image asset(s)", category: "photos", level: .info)
            result.enumerateObjects { asset, _, _ in
                if !seen.contains(asset.localIdentifier) {
                    seen.insert(asset.localIdentifier)
                    collected.append(asset)
                }
            }
        }
        collected.sort {
            ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }
        if collected.count > limit { collected = Array(collected.prefix(limit)) }
        return collected
    }

    /// Load all albums. Deferred until user opens the AlbumDrawerSheet.
    /// Runs in background to avoid blocking the main thread.
    func loadAlbums() async {
        if ScreenshotMode.isActive { return }

        isLoadingAlbums = true
        defer { isLoadingAlbums = false }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        let defaults = UserDefaults.standard
        let hasPersisted = defaults.object(forKey: enabledAlbumsKey) != nil
        let persistedEnabled = Set(defaults.stringArray(forKey: enabledAlbumsKey) ?? [])

        // Snapshot backed-up identifiers on MainActor before going off-thread.
        // Set<String> is Sendable so it can cross the actor boundary safely.
        let backedUpIds: Set<String> = services?.photoBackup.backedUpIdentifiers ?? []

        // Album toggles — smart albums with photo count > 0.
        // Run in a background task so it doesn't block the main thread.
        await Task.detached(priority: .userInitiated) {
            var albumResult: [AlbumItem] = []
            let smartAlbums = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: .any, options: nil)
            smartAlbums.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                guard assets.count > 0 else { return }
                let isEnabled: Bool = hasPersisted
                    ? persistedEnabled.contains(collection.localIdentifier)
                    : collection.localizedTitle == "Recents"
                var backed = 0
                assets.enumerateObjects { asset, _, _ in
                    if backedUpIds.contains(asset.localIdentifier) { backed += 1 }
                }
                albumResult.append(AlbumItem(
                    id: collection.localIdentifier,
                    name: collection.localizedTitle ?? "Album",
                    count: assets.count,
                    isEnabled: isEnabled,
                    backedUpCount: backed
                ))
            }
            await MainActor.run {
                self.albums = albumResult
            }
        }.value
    }

    func toggleAlbum(_ album: AlbumItem, enabled: Bool) {
        if let idx = albums.firstIndex(where: { $0.id == album.id }) {
            albums[idx].isEnabled = enabled
        }
        // Persist the full current set so unchecking the last album still
        // writes an empty array (distinguishable from first-run via key presence).
        let enabledIDs = albums.filter(\.isEnabled).map(\.id)
        UserDefaults.standard.set(enabledIDs, forKey: enabledAlbumsKey)
        dlog("toggleAlbum: '\(album.name)' (\(String(album.id.prefix(12)))) → enabled=\(enabled), persisted \(enabledIDs.count) id(s)", category: "photos", level: .info)

        guard let services = self.services else {
            logger.error("toggleAlbum called before VaultServices was wired")
            return
        }
        if enabled {
            services.photoBackup.startAlbumBackup(albumId: album.id)
        } else {
            services.photoBackup.stopAlbumBackup(albumId: album.id, apiClient: services.apiClient)
            Task { @MainActor in
                await services.photoBackup.unsyncAlbum(
                    albumId: album.id, apiClient: services.apiClient)
            }
        }
        // Re-fetch the grid against the new album selection so the visible
        // set reflects the toggle immediately. Disabling the last album
        // empties the grid; enabling a new one expands the union.
        Task { @MainActor in await loadRecentPhotos() }
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

