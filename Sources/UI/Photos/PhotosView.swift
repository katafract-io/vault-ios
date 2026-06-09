import SwiftUI
import Photos
import KatafractStyle

struct PhotosView: View {
    @EnvironmentObject private var services: VaultServices
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @StateObject private var viewModel = PhotosViewModel()
    @State private var showPaywall = false
    @State private var showAlbumsSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Backup status banners — show bulk backup first if active
                    if viewModel.bulkBackupActive {
                        BackupProgressBanner(
                            progress: viewModel.bulkBackupProgress,
                            remaining: viewModel.bulkBackupRemaining,
                            isBulkBackup: true
                        )
                    } else if viewModel.backupInProgress {
                        BackupProgressBanner(
                            progress: viewModel.backupProgress,
                            remaining: viewModel.remainingCount,
                            isBulkBackup: false
                        )
                    } else if viewModel.allBackedUp {
                        BackupCompleteBanner()
                    }

                    // Header with Albums button
                    HStack {
                        Text("RECENT PHOTOS")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showAlbumsSheet = true
                        } label: {
                            HStack(spacing: 4) {
                                Text("Choose Albums")
                                Image(systemName: "chevron.down")
                            }
                            .font(.caption)
                            .foregroundStyle(Color.kataGold)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, viewModel.totalBackedUpCount > 0 ? 4 : 12)

                    if viewModel.totalBackedUpCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.kataGold.opacity(0.75))
                            Text("\(viewModel.totalBackedUpCount) \(viewModel.totalBackedUpCount == 1 ? "photo" : "photos") · \(ByteCountFormatter.string(fromByteCount: viewModel.totalBackedUpBytes, countStyle: .file)) secured")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                    }

                    Divider().padding(.vertical, 8)

                    // Recently Backed Up section (last 7 days)
                    if !viewModel.recentlyBackedUpByDate.isEmpty {
                        RecentlyBackedUpSection(
                            groupedPhotos: viewModel.recentlyBackedUpByDate,
                            onPhotoTap: { viewModel.selectedPhoto = $0 }
                        )
                        .padding(.bottom, 12)

                        Divider().padding(.vertical, 8)
                    }

                    // Photo grid OR empty state
                    if showEmptyState {
                        PhotosEmptyStateView(onBackupTap: {
                            if subscriptionStore.isSubscribed {
                                viewModel.startBackupNow()
                            } else {
                                showPaywall = true
                            }
                        })
                        .padding(.top, 24)
                    } else {
                        PhotoGridSection(
                            photos: viewModel.backedUpPhotos,
                            onPhotoTap: { viewModel.selectedPhoto = $0 },
                            onLastPhotoAppear: {
                                Task {
                                    await viewModel.loadMore()
                                }
                            },
                            isLoadingMore: viewModel.isLoadingMore
                        )
                    }
                }
            }
            .navigationTitle("Photos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        // Bulk backup toggle
                        Button {
                            if viewModel.bulkBackupActive {
                                viewModel.stopFullLibraryBackup()
                            } else {
                                if subscriptionStore.isSubscribed {
                                    viewModel.startFullLibraryBackup()
                                } else {
                                    showPaywall = true
                                }
                            }
                        } label: {
                            Image(systemName: viewModel.bulkBackupActive ? "bolt.fill" : "bolt")
                        }
                        .tint(viewModel.bulkBackupActive ? .orange : .primary)

                        // Backup Now button
                        Button {
                            if subscriptionStore.isSubscribed {
                                viewModel.startBackupNow()
                            } else {
                                showPaywall = true
                            }
                        } label: {
                            Label("Backup Now", systemImage: "arrow.clockwise.icloud")
                        }
                        .disabled(viewModel.backupInProgress || viewModel.bulkBackupActive)
                    }
                }
            }
            .task {
                viewModel.configure(services: services)
                await viewModel.loadRecentPhotos()
            }
            .sheet(item: $viewModel.selectedPhoto) { photo in
                PhotoDetailView(
                    photo: photo,
                    onDelete: {
                        viewModel.removeFromBackup(photo)
                    },
                    onBackupNow: {
                        // Back up this single photo
                        Task {
                            viewModel.backupSinglePhoto(photo)
                        }
                    }
                )
            }
            .sheet(isPresented: $showAlbumsSheet) {
                AlbumPickerSheet(onSave: {
                    Task {
                        await viewModel.loadRecentPhotos()
                    }
                })
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(capacity: .tb1)
            }
        }
    }

    private var showEmptyState: Bool {
        !viewModel.backupInProgress &&
        !viewModel.backedUpPhotos.contains(where: { $0.backupState == .syncedAndLocal })
    }
}

// MARK: - Photos empty state — "sealed album"

struct PhotosEmptyStateView: View {
    var onBackupTap: () -> Void

    @State private var cardScale: CGFloat = 0.92
    @State private var cardOpacity: Double = 0
    @State private var borderProgress: CGFloat = 0

    var body: some View {
        VStack(spacing: 20) {
            sealedAlbumCard

            VStack(spacing: 8) {
                Text("No photos yet — sealed and waiting.")
                    .font(.kataHeadline(22, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text("Back up your photo library. Everything is encrypted on this device before it leaves.")
                    .font(.kataBody(14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button(action: onBackupTap) {
                Label("Back up photos", systemImage: "arrow.up.circle.fill")
                    .font(.kataHeadline(15, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: 240)
                    .frame(height: 48)
                    .background(Color.kataPremiumGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.top, 4)
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(duration: 0.6, bounce: 0.2)) {
                cardScale = 1.0
                cardOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.9).delay(0.2)) {
                borderProgress = 1.0
            }
        }
    }

    private var sealedAlbumCard: some View {
        ZStack {
            // Base card with sapphire gradient
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color.kataSapphire.opacity(0.25),
                        Color.kataSapphire.opacity(0.6)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .background(Color.black.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous))

            // Photo-grid watermark (3×4) at low opacity
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(0..<12, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(18)
            .allowsHitTesting(false)

            // Centered shield overlay
            ZStack {
                Image(systemName: "shield.fill")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(LinearGradient(
                        colors: [.kataSapphire, .kataSapphire.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))

                Image(systemName: "photo.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.kataGold)
                    .offset(y: 2)
            }

            // Gold hairline border (animated draw)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .trim(from: 0, to: borderProgress)
                .stroke(Color.kataGold.opacity(0.35), lineWidth: 0.5)
        }
        .frame(width: 180, height: 240)
        .scaleEffect(cardScale)
        .opacity(cardOpacity)
    }
}

struct BackupProgressBanner: View {
    let progress: Double
    let remaining: Int
    var isBulkBackup: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            KataProgressRing(progress: progress, size: 24)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                if isBulkBackup {
                    Text("Backing up entire library")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                Text("\(remaining) remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(isBulkBackup ? Color(.systemOrange).opacity(0.1) : Color(.systemBlue).opacity(0.1))
    }
}

struct BackupCompleteBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "checkmark.icloud.fill")
                .foregroundStyle(.green)
            Text("All photos backed up")
                .font(.subheadline)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGreen).opacity(0.1))
    }
}

struct PhotoGridSection: View {
    let photos: [BackedUpPhoto]
    var onPhotoTap: (BackedUpPhoto) -> Void
    var onLastPhotoAppear: (() -> Void)? = nil
    var isLoadingMore: Bool = false
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    private var backedUpCount: Int {
        photos.filter { $0.backupState == .syncedAndLocal }.count
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(backedUpCount) of \(photos.count) PHOTOS BACKED UP")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    // Fixed-aspect container. PhotoThumbnailView fills and
                    // clips itself internally, so there's no nested
                    // aspect-ratio fight when the image arrives.
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            PhotoThumbnailView(
                                assetLocalIdentifier: photo.isCloudOnly ? nil : photo.id,
                                targetSize: CGSize(width: 120, height: 120),
                                isCloudOnly: photo.isCloudOnly)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            CustodyBadge(state: photo.isCloudOnly ? .inVault : [.inVault, .onDevice])
                                .padding(4)
                        }
                        .overlay(alignment: .topTrailing) {
                            BackupStateBadge(state: photo.backupState)
                                .padding(4)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onPhotoTap(photo) }
                        .onAppear {
                            // Trigger loadMore when user scrolls to the last or near-last item
                            // Load when within 10 items of the end to fetch proactively
                            if index >= photos.count - 10 {
                                onLastPhotoAppear?()
                            }
                        }
                }
            }

            // Loading indicator when pagination is in progress
            if isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Spacer()
                }
                .padding()
            }
        }
    }
}

/// Small corner badge indicating whether a photo is backed up, pending,
/// Renders 4 sync states: synced (hidden), local-only (pending), cloud-only
/// (download), or syncing (progress ring).
struct BackupStateBadge: View {
    let state: BackedUpPhoto.BackupState

    var body: some View {
        switch state {
        case .syncedAndLocal:
            EmptyView()
        case .localOnly:
            Image(systemName: "icloud.slash")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(3)
                .background(Circle().fill(Color.black.opacity(0.4)))
        case .cloudOnly:
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
                .padding(3)
                .background(Circle().fill(Color.black.opacity(0.4)))
        case .syncing(let progress):
            ZStack {
                Circle().fill(Color.black.opacity(0.4)).frame(width: 18, height: 18)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

struct PhotoDetailView: View {
    let photo: BackedUpPhoto
    /// Invoked when the user taps Delete. Caller is responsible for the
    /// soft-delete + BackedUpAsset removal; this view only requests it.
    var onDelete: (() -> Void)? = nil
    /// Invoked to back up a single pending photo.
    var onBackupNow: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Sync state header
                syncStateHeader
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .background(Color(.systemGray6))

                // Photo viewer
                PhotoThumbnailView(
                    assetLocalIdentifier: photo.isCloudOnly ? nil : photo.id,
                    targetSize: UIScreen.main.bounds.size,
                    contentMode: .aspectFit,
                    isCloudOnly: photo.isCloudOnly
                )
                .ignoresSafeArea()
            }
            .navigationTitle(photo.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if case .syncedAndLocal = photo.backupState, onDelete != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Remove from vault")
                    }
                }
            }
            .confirmationDialog(
                "Remove from vault?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The encrypted backup will be moved to the recycle bin. The photo on this device is not affected.")
            }
        }
    }

    private var syncStateHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch photo.backupState {
            case .syncedAndLocal:
                syncedState

            case .localOnly:
                localOnlyState

            case .syncing(let progress):
                syncingState(progress: progress)

            case .cloudOnly:
                cloudOnlyState
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var syncedState: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(Color.kataGold)
                Text("Backed up")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            Text("\(ByteCountFormatter.string(fromByteCount: Int64(photo.sizeBytes), countStyle: .file)) encrypted")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var localOnlyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "icloud.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Pending")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            Button(action: { onBackupNow?() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                    Text("Back up now")
                }
                .font(.caption)
                .foregroundStyle(Color.black.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.kataGold)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private func syncingState(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                KataProgressRing(progress: progress, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uploading")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cloudOnlyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("Cloud only")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            Text("This photo was deleted from your device")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Recently Backed Up Section

struct RecentlyBackedUpSection: View {
    let groupedPhotos: [String: [BackedUpPhoto]]
    var onPhotoTap: (BackedUpPhoto) -> Void

    private let categories = ["Today", "Yesterday", "This Week"]
    private let horizontalSpacing: CGFloat = 8
    private let thumbnailSize: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RECENTLY BACKED UP")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(categories, id: \.self) { category in
                    if let photos = groupedPhotos[category], !photos.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .padding(.horizontal)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: horizontalSpacing) {
                                    ForEach(photos, id: \.id) { photo in
                                        VStack(spacing: 4) {
                                            ZStack {
                                                Color.clear
                                                    .aspectRatio(1, contentMode: .fit)
                                                    .frame(width: thumbnailSize, height: thumbnailSize)
                                                    .overlay {
                                                        PhotoThumbnailView(
                                                            assetLocalIdentifier: photo.isCloudOnly ? nil : photo.id,
                                                            targetSize: CGSize(width: thumbnailSize, height: thumbnailSize),
                                                            isCloudOnly: photo.isCloudOnly
                                                        )
                                                    }
                                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                                    .contentShape(Rectangle())
                                                    .onTapGesture {
                                                        onPhotoTap(photo)
                                                    }
                                            }

                                            Text(photo.takenAt, style: .time)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .frame(width: thumbnailSize)
                                                .lineLimit(1)
                                        }
                                        .frame(width: thumbnailSize)
                                    }

                                    Spacer()
                                        .frame(width: 1)
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    PhotosView()
}
