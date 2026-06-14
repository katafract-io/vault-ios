import Foundation
import OSLog
import Photos
import SwiftUI
import SwiftData

struct PhotoAlbumItem: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
    var isEnabled: Bool
    var backedUpCount: Int = 0
}

/// A photo in the grid — either in the local library or in vault only (cloud-only).
/// Thumbnails are fetched lazily via PHImageManager for local assets (see
/// `PhotoThumbnailView`). Cloud-only photos use vault thumbnails or placeholder.
struct BackedUpPhoto: Identifiable, Hashable {
    let id: String               // PHAsset.localIdentifier or BackedUpAsset.assetIdentifier
    let filename: String
    let sizeBytes: Int
    let takenAt: Date
    var backupState: BackupState
    let isCloudOnly: Bool        // true if in vault but deleted from device

    enum BackupState: Hashable {
        case syncedAndLocal      // in photo roll AND in vault
        case localOnly           // in photo roll, NOT yet uploaded
        case cloudOnly           // in vault, NOT in photo roll (user deleted locally)
        case syncing(Double)     // upload in flight
    }

    static func == (lhs: BackedUpPhoto, rhs: BackedUpPhoto) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
class PhotosViewModel: ObservableObject {
    @Published var albums: [PhotoAlbumItem] = []
    @Published var backedUpPhotos: [BackedUpPhoto] = []
    @Published var backupInProgress = false
    @Published var backupProgress: Double = 0
    @Published var remainingCount = 0
    @Published var allBackedUp = false
    @Published var selectedPhoto: BackedUpPhoto?
    @Published var isLoadingAlbums = false
    /// True when the user has made at least one toggle choice and the current
    /// selection is empty (all albums off). Drives the "Choose albums" empty state.
    @Published var isAlbumSelectionEmpty = false
    /// Non-nil when one or more photos failed to upload during the last backup
    /// run. Cleared when the user dismisses the error alert.
    @Published var uploadErrorMessage: String? = nil
    @Published var bulkBackupActive = false
    @Published var bulkBackupProgress: Double = 0
    @Published var bulkBackupRemaining = 0

    // Pagination state
    @Published var isLoadingMore = false
    @Published var hasMorePhotos = true
    private var currentOffset = 0
    private let paginationBatchSize = 60
    private let maxVisiblePhotos = 600

    var totalBackedUpCount: Int {
        backedUpPhotos.filter { $0.backupState == .syncedAndLocal }.count
    }
    var totalBackedUpBytes: Int64 {
        backedUpPhotos.filter { $0.backupState == .syncedAndLocal }.reduce(Int64(0)) { $0 + Int64($1.sizeBytes) }
    }

    private weak var services: VaultServices?

    /// UserDefaults key holding the array of enabled album localIdentifiers.
    /// Presence of the key (even with an empty array) means the user has
    /// interacted with toggles at least once — on subsequent loads we use
    /// their stored set verbatim. Absence means first-run, and we default to
    /// Recents-only.
    private let enabledAlbumsKey = "enabledAlbumIds"

    func configure(services: VaultServices) {
        self.services = services
    }

    /// Load recent photos from VaultIndex (with pagination support),
    /// plus cloud-only photos (in vault but deleted from device).
    /// Queries the local SwiftData cache for VaultIndexItem rows with mime LIKE 'image/%'.
    /// In ScreenshotMode, injects synthetic seed photos instead.
    ///
    /// When called with offset=0 (default), resets the pagination state and loads
    /// the first batch. When called with offset>0, appends new photos (pagination).
    func loadRecentPhotos(offset: Int = 0) async {
        if ScreenshotMode.seedData != nil {
            injectSeedPhotos()
            return
        }
        if ScreenshotMode.isActive { return }

        guard let services = self.services else {
            backedUpPhotos = []
            return
        }

        // Reset pagination on initial load
        if offset == 0 {
            currentOffset = 0
            backedUpPhotos = []
            hasMorePhotos = true
        }

        let context = ModelContext(services.modelContainer)
        let logMsg = offset == 0 ? "initial load" : "pagination (offset: \(offset))"
        dlog("loadRecentPhotos: \(logMsg) querying LocalFile for backed-up photos", category: "photos", level: .info)

        // Source from LocalFile — the model the upload + tree-sync paths
        // populate. (VaultIndexItem is fed only by VaultIndexDeltaSync from the
        // server `vault_manifest` table, which the upload path never writes, so
        // it was always empty and the grid showed nothing.) Photo-roll backups
        // carry `sourceAssetIdentifier`; that's what the grid keys thumbnails on.
        let allFiles = (try? context.fetch(FetchDescriptor<LocalFile>(
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]))) ?? []
        let photoFiles = allFiles.filter {
            $0.syncState != "deleted" && $0.sourceAssetIdentifier != nil
        }
        dlog("loadRecentPhotos: \(photoFiles.count) backed-up photo(s) in vault", category: "photos", level: .info)

        // Manual pagination over the filtered set (extension/identifier filters
        // can't run inside a SwiftData #Predicate).
        let page = Array(photoFiles.dropFirst(offset).prefix(paginationBatchSize + 1))
        hasMorePhotos = page.count > paginationBatchSize
        let itemsToProcess = Array(page.prefix(paginationBatchSize))

        var newPhotos: [BackedUpPhoto] = itemsToProcess.map { f in
            BackedUpPhoto(
                id: f.sourceAssetIdentifier ?? f.fileId,
                filename: f.filename,
                sizeBytes: Int(f.sizeBytes),
                takenAt: f.modifiedAt,
                backupState: .syncedAndLocal,
                isCloudOnly: false
            )
        }

        // On initial load, include cloud-only photos (in vault, deleted from device)
        if offset == 0 {
            let localAssetIds = Set(itemsToProcess.compactMap { $0.sourceAssetIdentifier })
            let cloudOnlyPhotos = await fetchCloudOnlyPhotos(
                excludeLocalIds: localAssetIds, modelContainer: services.modelContainer)
            newPhotos.append(contentsOf: cloudOnlyPhotos)
            newPhotos.sort { $0.takenAt > $1.takenAt }
            backedUpPhotos = newPhotos
        } else {
            backedUpPhotos.append(contentsOf: newPhotos)
        }

        currentOffset = offset + paginationBatchSize

        // Apply memory cap: keep only the latest 600 items
        if backedUpPhotos.count > maxVisiblePhotos {
            backedUpPhotos = Array(backedUpPhotos.prefix(maxVisiblePhotos))
        }

        allBackedUp = !backedUpPhotos.isEmpty && backedUpPhotos.allSatisfy { $0.backupState == .syncedAndLocal }
    }

    /// Load more photos when user scrolls past the last visible item.
    /// Called from UI when the last photo appears on screen.
    /// Only loads if not already loading and more photos exist.
    func loadMore() async {
        guard !isLoadingMore && hasMorePhotos else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        await loadRecentPhotos(offset: currentOffset)
    }

    /// Fetch BackedUpAssets whose assetIdentifiers don't resolve to live PHAssets.
    /// Returns them as BackedUpPhoto items with .cloudOnly state.
    private func fetchCloudOnlyPhotos(
        excludeLocalIds: Set<String>,
        modelContainer: ModelContainer?
    ) async -> [BackedUpPhoto] {
        guard let container = modelContainer else { return [] }

        return await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<BackedUpAsset>()
            descriptor.fetchLimit = 1000  // Safety limit

            guard let allBackedUp = try? context.fetch(descriptor) else { return [] }

            // Filter to BackedUpAssets not in the live PHAsset collection.
            let cloudOnly = allBackedUp.filter { !excludeLocalIds.contains($0.assetIdentifier) }

            return cloudOnly.map { asset in
                BackedUpPhoto(
                    id: asset.assetIdentifier,
                    filename: asset.originalFilename,
                    sizeBytes: Int(asset.sizeBytes),
                    takenAt: asset.backedUpAt,
                    backupState: .cloudOnly,
                    isCloudOnly: true
                )
            }
        }.value
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
        let result = await Task.detached(priority: .userInitiated) { () -> [PhotoAlbumItem] in
            var albumResult: [PhotoAlbumItem] = []
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
                albumResult.append(PhotoAlbumItem(
                    id: collection.localIdentifier,
                    name: collection.localizedTitle ?? "Album",
                    count: assets.count,
                    isEnabled: isEnabled,
                    backedUpCount: backed
                ))
            }
            return albumResult
        }.value
        self.albums = result
    }

    func toggleAlbum(_ album: PhotoAlbumItem, enabled: Bool) {
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
            $0.backupState != .syncedAndLocal
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
            allBackedUp = backedUpPhotos.allSatisfy { $0.backupState == .syncedAndLocal }
        }

        let total = pendingIDs.count
        var done = 0

        for assetID in pendingIDs {
            done += 1
            updateAssetState(id: assetID, to: .syncing(0.0))

            // Resolve PHAsset by localIdentifier.
            let fetchOpts = PHFetchOptions()
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: fetchOpts)
            guard let asset = assets.firstObject else {
                logger.error("PHAsset \(assetID, privacy: .public) not found in library")
                dlog("PHAsset not found for \(assetID)", category: "photos", level: .error)
                updateAssetState(id: assetID, to: .localOnly)
                advanceProgress(done: done, total: total)
                continue
            }

            do {
                let fileId = try await services.photoBackup.enqueueAsset(asset)
                updateAssetState(id: assetID, to: .syncedAndLocal)
                logger.info("photo backed up: \(assetID, privacy: .public) → \(fileId, privacy: .public)")
            } catch {
                logger.error("photo backup failed for \(assetID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                dlog("photo backup failed for \(assetID): \(error.localizedDescription)", category: "photos", level: .error)
                updateAssetState(id: assetID, to: .localOnly)
            }

            advanceProgress(done: done, total: total)
        }
    }

    private func updateAssetState(id: String, to newState: BackedUpPhoto.BackupState) {
        if let idx = backedUpPhotos.firstIndex(where: { $0.id == id }) {
            backedUpPhotos[idx].backupState = newState
        }
    }

    /// Back up a single pending photo.
    /// - Parameter photo: The photo to back up (typically in .localOnly state)
    func backupSinglePhoto(_ photo: BackedUpPhoto) {
        guard let services = self.services else {
            logger.error("backupSinglePhoto called before VaultServices was wired")
            return
        }

        let assetId = photo.id
        Task { @MainActor in
            // Mark as syncing
            updateAssetState(id: assetId, to: .syncing(0.0))

            // Resolve PHAsset by localIdentifier.
            let fetchOpts = PHFetchOptions()
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: fetchOpts)
            guard let asset = assets.firstObject else {
                logger.error("PHAsset \(assetId, privacy: .public) not found in library")
                updateAssetState(id: assetId, to: .localOnly)
                return
            }

            do {
                _ = try await services.photoBackup.enqueueAsset(asset)
                updateAssetState(id: assetId, to: .syncedAndLocal)
                logger.info("single photo backed up: \(assetId, privacy: .public)")
                allBackedUp = !backedUpPhotos.isEmpty && backedUpPhotos.allSatisfy { $0.backupState == .syncedAndLocal }
            } catch {
                logger.error("single photo backup failed for \(assetId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                updateAssetState(id: assetId, to: .localOnly)
            }
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
            updateAssetState(id: assetId, to: .localOnly)
            allBackedUp = !backedUpPhotos.isEmpty && backedUpPhotos.allSatisfy { $0.backupState == .syncedAndLocal }
        }
    }

    private func advanceProgress(done: Int, total: Int) {
        backupProgress = total > 0 ? Double(done) / Double(total) : 1.0
        remainingCount = max(0, total - done)
    }

    /// Start backing up the entire photo library with progress tracking.
    func startFullLibraryBackup() {
        guard let services = self.services else {
            logger.error("startFullLibraryBackup called before VaultServices was wired")
            return
        }
        services.photoBackup.startFullLibraryBackup()
        bulkBackupActive = true
        setupBulkBackupMonitoring()
    }

    /// Stop the full library bulk backup.
    func stopFullLibraryBackup() {
        guard let services = self.services else {
            logger.error("stopFullLibraryBackup called before VaultServices was wired")
            return
        }
        services.photoBackup.stopFullLibraryBackup()
        bulkBackupActive = false
        bulkBackupProgress = 0
        bulkBackupRemaining = 0
    }

    /// Monitor bulk backup state changes and update progress UI.
    private func setupBulkBackupMonitoring() {
        Task { [weak self] in
            while true {
                guard let self else { break }
                guard let state = self.services?.photoBackup.bulkBackupState else {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                    continue
                }

                await MainActor.run {
                    self.bulkBackupActive = state.isActive
                    if state.totalToBackup > 0 {
                        self.bulkBackupProgress = Double(state.completedCount) / Double(state.totalToBackup)
                        self.bulkBackupRemaining = state.totalToBackup - state.completedCount
                    }
                }

                if !state.isActive {
                    break
                }

                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            }
        }
    }

    /// Injects synthetic seed photos for XCUITest screenshot runs.
    private func injectSeedPhotos() {
        let seedPhotos = [
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Sunset at Acadia.heic",
                sizeBytes: 3_200_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 2),
                backupState: .syncedAndLocal,
                isCloudOnly: false
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Coffee Morning.jpeg",
                sizeBytes: 1_400_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 3),
                backupState: .syncedAndLocal,
                isCloudOnly: false
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Garden Update.heic",
                sizeBytes: 4_100_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 5),
                backupState: .syncedAndLocal,
                isCloudOnly: false
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Birthday Cake.jpeg",
                sizeBytes: 2_300_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 7),
                backupState: .localOnly,
                isCloudOnly: false
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Mountain Trek.heic",
                sizeBytes: 5_600_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 9),
                backupState: .syncing(0.35),
                isCloudOnly: false
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Beach Day.jpeg",
                sizeBytes: 3_800_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 12),
                backupState: .syncedAndLocal,
                isCloudOnly: false
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Concert Night.heic",
                sizeBytes: 6_200_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 15),
                backupState: .syncedAndLocal,
                isCloudOnly: false
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Restaurant Plating.jpeg",
                sizeBytes: 2_900_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 18),
                backupState: .cloudOnly,
                isCloudOnly: true
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Autumn Leaves.heic",
                sizeBytes: 4_700_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 21),
                backupState: .syncedAndLocal,
                isCloudOnly: false
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Hiking Summit.jpeg",
                sizeBytes: 3_500_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 25),
                backupState: .localOnly,
                isCloudOnly: false
            ),
        ]
        backedUpPhotos = seedPhotos
        allBackedUp = seedPhotos.allSatisfy { $0.backupState == .syncedAndLocal }
    }

    /// Groups recently backed up photos (last 7 days) by date category.
    /// Returns a dictionary mapping category names (Today, Yesterday, This Week)
    /// to arrays of photos, sorted by date descending within each group.
    var recentlyBackedUpByDate: [String: [BackedUpPhoto]] {
        let now = Date()
        let calendar = Calendar.current
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        // Filter photos from last 7 days that are backed up
        let recent = backedUpPhotos.filter { photo in
            photo.takenAt >= sevenDaysAgo && photo.takenAt <= now &&
            photo.backupState == .syncedAndLocal
        }

        var grouped: [String: [BackedUpPhoto]] = [:]

        for photo in recent {
            let category = dateCategory(for: photo.takenAt, now: now, calendar: calendar)
            if grouped[category] == nil {
                grouped[category] = []
            }
            grouped[category]?.append(photo)
        }

        // Sort photos within each group by date descending
        for key in grouped.keys {
            grouped[key]?.sort { $0.takenAt > $1.takenAt }
        }

        return grouped
    }

    /// Determines the category label for a given date relative to now.
    private func dateCategory(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return "This Week"
        }
    }
}

