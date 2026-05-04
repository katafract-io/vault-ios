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
            VStack(spacing: 0) {
                if viewModel.backupInProgress {
                    BackupProgressBanner(
                        progress: viewModel.backupProgress,
                        remaining: viewModel.remainingCount
                    )
                } else if viewModel.allBackedUp {
                    BackupCompleteBanner()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
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
                                    Text("Albums")
                                    Image(systemName: "chevron.down")
                                }
                                .font(.caption)
                                .foregroundStyle(Color.kataGold)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 12)

                        Divider().padding(.vertical, 8)

                        // Photo grid OR sealed-album empty state
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
                                onPhotoTap: { viewModel.selectedPhoto = $0 }
                            )
                        }
                    }
                }
            }
            .navigationTitle("Photos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if subscriptionStore.isSubscribed {
                            viewModel.startBackupNow()
                        } else {
                            showPaywall = true
                        }
                    } label: {
                        Label("Backup Now", systemImage: "arrow.clockwise.icloud")
                    }
                    .disabled(viewModel.backupInProgress)
                }
            }
            .task {
                viewModel.configure(services: services)
                await viewModel.loadRecentPhotos()
            }
            .sheet(item: $viewModel.selectedPhoto) { photo in
                PhotoDetailView(photo: photo, onDelete: {
                    viewModel.removeFromBackup(photo)
                })
            }
            .sheet(isPresented: $showAlbumsSheet) {
                AlbumDrawerSheet(
                    isPresented: $showAlbumsSheet,
                    albums: viewModel.albums,
                    isLoading: viewModel.isLoadingAlbums,
                    onToggle: viewModel.toggleAlbum,
                    onAppear: { await viewModel.loadAlbums() }
                )
            }
            .sheet(isPresented: $showPaywall) {
                CapacityPickerView()
            }
        }
    }

    private var showEmptyState: Bool {
        !viewModel.backupInProgress &&
        !viewModel.backedUpPhotos.contains(where: { $0.backupState == .backedUp })
    }
}

// MARK: - Album Drawer Sheet

struct AlbumDrawerSheet: View {
    @Binding var isPresented: Bool
    let albums: [AlbumItem]
    let isLoading: Bool
    var onToggle: (AlbumItem, Bool) -> Void
    var onAppear: () async -> Void

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Loading albums...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(height: 100)
                } else if albums.isEmpty {
                    HStack {
                        Spacer()
                        Text("No albums")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(height: 60)
                } else {
                    ForEach(albums) { album in
                        HStack {
                            // Album thumbnail
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(.systemGray5))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Image(systemName: "photo.on.rectangle")
                                        .foregroundStyle(.secondary)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.name).font(.body)
                                Text("\(album.count) photos").font(.caption).foregroundStyle(.secondary)
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { album.isEnabled },
                                set: { onToggle(album, $0) }
                            ))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { isPresented = false }
                }
            }
            .task {
                await onAppear()
            }
        }
        .presentationDetents([.medium, .large])
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

    var body: some View {
        HStack(spacing: 12) {
            KataProgressRing(progress: progress, size: 24)
                .frame(maxWidth: .infinity)
            Text("\(remaining) remaining")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.systemBlue).opacity(0.1))
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
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    private var backedUpCount: Int {
        photos.filter { $0.backupState == .backedUp }.count
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(backedUpCount) of \(photos.count) PHOTOS BACKED UP")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(photos) { photo in
                    // Fixed-aspect container. PhotoThumbnailView fills and
                    // clips itself internally, so there's no nested
                    // aspect-ratio fight when the image arrives.
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            PhotoThumbnailView(
                                assetLocalIdentifier: photo.id,
                                targetSize: CGSize(width: 120, height: 120))
                        }
                        .overlay(alignment: .bottomTrailing) {
                            BackupStateBadge(state: photo.backupState)
                                .padding(4)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onPhotoTap(photo) }
                }
            }
        }
    }
}

/// Small corner badge indicating whether a photo is backed up, pending,
/// uploading, or failed. Stays out of the way for `.backedUp` (invisible).
struct BackupStateBadge: View {
    let state: BackedUpPhoto.BackupState

    var body: some View {
        switch state {
        case .backedUp:
            EmptyView()
        case .pending:
            Image(systemName: "icloud.slash")
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(3)
                .background(Circle().fill(Color.black.opacity(0.4)))
        case .uploading(let progress):
            ZStack {
                Circle().fill(Color.black.opacity(0.4)).frame(width: 18, height: 18)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(-90))
            }
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}

struct PhotoDetailView: View {
    let photo: BackedUpPhoto
    /// Invoked when the user taps Delete. Caller is responsible for the
    /// soft-delete + BackedUpAsset removal; this view only requests it.
    var onDelete: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            PhotoThumbnailView(
                assetLocalIdentifier: photo.id,
                targetSize: UIScreen.main.bounds.size,
                contentMode: .aspectFit
            )
            .ignoresSafeArea()
            .navigationTitle(photo.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if photo.backupState == .backedUp, onDelete != nil {
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
}

#Preview {
    PhotosView()
}
