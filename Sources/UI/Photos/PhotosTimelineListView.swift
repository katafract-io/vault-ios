import SwiftUI
import Photos
import KatafractStyle

struct PhotosTimelineListView: View {
    let photosByMonth: [(month: String, photos: [BackedUpPhoto])]
    var onPhotoTap: (BackedUpPhoto) -> Void

    var body: some View {
        List {
            ForEach(photosByMonth, id: \.month) { section in
                Section(header: Text("\(section.month.uppercased()) - \(section.photos.count) \(section.photos.count == 1 ? "photo" : "photos")")) {
                    ForEach(section.photos) { photo in
                        PhotoListRow(photo: photo, onTap: {
                            onPhotoTap(photo)
                        })
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

struct PhotoListRow: View {
    let photo: BackedUpPhoto
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(width: 60, height: 60)
                .overlay {
                    PhotoThumbnailView(
                        assetLocalIdentifier: photo.id,
                        targetSize: CGSize(width: 60, height: 60))
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(photo.filename)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(formatDate(photo.takenAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(formatBytes(photo.sizeBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Backup state badge
            Image(systemName: statusIcon(for: photo.backupState))
                .font(.caption)
                .foregroundStyle(statusColor(for: photo.backupState))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1_000_000 {
            return "\(bytes / 1000) KB"
        } else if bytes < 1_000_000_000 {
            let mb = Double(bytes) / 1_000_000
            return String(format: "%.1f MB", mb)
        } else {
            let gb = Double(bytes) / 1_000_000_000
            return String(format: "%.1f GB", gb)
        }
    }

    private func statusIcon(for state: BackedUpPhoto.BackupState) -> String {
        switch state {
        case .backedUp:
            return "lock.shield.fill"
        case .pending:
            return "icloud.slash"
        case .uploading:
            return "arrow.up.circle"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }

    private func statusColor(for state: BackedUpPhoto.BackupState) -> Color {
        switch state {
        case .backedUp:
            return .green
        case .pending:
            return .secondary
        case .uploading:
            return .blue
        case .failed:
            return .red
        }
    }
}
