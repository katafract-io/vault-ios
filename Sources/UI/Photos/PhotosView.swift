import SwiftUI
import Photos

struct PhotosView: View {
    @EnvironmentObject private var services: VaultServices
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @StateObject private var viewModel = PhotosViewModel()
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Backup status banner
                    if viewModel.backupInProgress {
                        BackupProgressBanner(
                            progress: viewModel.backupProgress,
                            remaining: viewModel.remainingCount
                        )
                    } else if viewModel.allBackedUp {
                        BackupCompleteBanner()
                    }

                    // Albums section
                    AlbumsSection(
                        albums: viewModel.albums,
                        onToggle: viewModel.toggleAlbum
                    )

                    Divider().padding(.vertical, 8)

                    // Photo grid
                    PhotoGridSection(
                        photos: viewModel.backedUpPhotos,
                        onPhotoTap: { viewModel.selectedPhoto = $0 }
                    )
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
                await viewModel.loadAlbums()
            }
            .sheet(item: $viewModel.selectedPhoto) { photo in
                PhotoDetailView(photo: photo)
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
        }
    }
}

struct BackupProgressBanner: View {
    let progress: Double
    let remaining: Int

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: progress)
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

struct AlbumsSection: View {
    let albums: [AlbumItem]
    var onToggle: (AlbumItem, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ALBUMS")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 8)

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
                .padding(.horizontal)
                .padding(.vertical, 8)
                Divider().padding(.leading, 72)
            }
        }
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
    @Environment(\.dismiss) private var dismiss

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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { } label: { Label("Share", systemImage: "square.and.arrow.up") }
                        Button { } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                        Divider()
                        Button(role: .destructive) { } label: { Label("Delete", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }
}

#Preview {
    PhotosView()
}
