import SwiftUI
import Photos
import KatafractStyle

struct PhotosTimelineGridView: View {
    let photosByMonth: [(month: String, photos: [BackedUpPhoto])]
    var onPhotoTap: (BackedUpPhoto) -> Void
    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(photosByMonth, id: \.month) { section in
                // Month header
                Text("\(section.month.uppercased()) - \(section.photos.count) \(section.photos.count == 1 ? "photo" : "photos")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                // Grid section
                // TODO: Replace PhotoThumbnailView with ThumbLoader once VaultIndex thumb_key integration lands.
                // Currently using PHAsset local identifiers; encrypted thumbnails via VaultIndex are pending.
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(section.photos) { photo in
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
                .padding(.horizontal, 2)
            }
        }
    }
}

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
