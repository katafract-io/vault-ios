import SwiftUI

struct GridView: View {
    let items: [VaultFileItem]
    var onSelect: (VaultFileItem) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(items) { item in
                    GridItemView(item: item)
                        .onTapGesture {
                            onSelect(item)
                        }
                }
            }
            .padding()
        }
    }
}

struct GridItemView: View {
    let item: VaultFileItem
    @State private var loadedThumbnail: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                if let thumb = loadedThumbnail ?? item.thumbnailImage {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                        .cornerRadius(8)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray5))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(FileIconView(item: item))
                }
                SyncStatusBadge(state: item.syncState)
                    .padding(4)
            }
            Text(item.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard !item.isFolder else { return }

        do {
            let thumbKey = try VaultCrypto.deriveKey(from: item.id)
            let mimeType = Self.mimeType(for: item.name)

            let thumb = await ThumbLoader.shared.loadThumbnail(
                fileId: item.id,
                size: .small,
                thumbKey: thumbKey,
                mimeType: mimeType
            )
            loadedThumbnail = thumb
        } catch {
            // Silently fail; show placeholder
        }
    }

    private static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        let mimeTypes: [String: String] = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "heic": "image/heic",
            "heif": "image/heif",
            "webp": "image/webp",
            "mov": "video/quicktime",
            "mp4": "video/mp4",
            "m4v": "video/mp4",
        ]
        return mimeTypes[ext] ?? "application/octet-stream"
    }
}

#Preview {
    GridView(items: [
        VaultFileItem(
            id: "1",
            name: "Photo 1",
            isFolder: false,
            sizeBytes: 3_000_000,
            modifiedAt: Date(),
            syncState: .synced,
            isPinned: false
        ),
        VaultFileItem(
            id: "2",
            name: "Documents",
            isFolder: true,
            sizeBytes: 0,
            modifiedAt: Date(),
            syncState: .synced,
            isPinned: false
        ),
    ])
}
