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
        guard loadedThumbnail == nil else { return }

        // 1. Server-side thumbnail (generated + uploaded on finalize).
        do {
            let thumbKey = try VaultCrypto.deriveKey(from: item.id)
            let mimeType = Self.mimeType(for: item.name)
            if let thumb = await ThumbLoader.shared.loadThumbnail(
                fileId: item.id,
                size: .small,
                thumbKey: thumbKey,
                mimeType: mimeType
            ) {
                loadedThumbnail = thumb
                return
            }
        } catch {
            print("[GridItemView] server thumbnail load error: \(error)")
        }

        // 2. Local fallback: render a preview straight from the plaintext kept
        //    in LocalCache (present for files imported/opened on this device),
        //    so pictures show a real preview even before a server thumbnail
        //    exists. Decode off the main actor to avoid grid scroll jank.
        let id = item.id
        let name = item.name
        if let local = await Task.detached(priority: .utility, operation: {
            Self.localThumbnail(fileId: id, filename: name)
        }).value {
            loadedThumbnail = local
        }
    }

    /// Build a downscaled preview from the local plaintext for image files.
    /// Returns nil for non-images or when the plaintext isn't cached locally.
    private static func localThumbnail(fileId: String, filename: String) -> UIImage? {
        guard mimeType(for: filename).hasPrefix("image/") else { return nil }
        let ext = (filename as NSString).pathExtension
        let cacheName = ext.isEmpty ? fileId : "\(fileId).\(ext)"
        let url = LocalCache.cacheURL.appendingPathComponent(cacheName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = UIImage(contentsOfFile: url.path) else { return nil }

        let maxDim: CGFloat = 300
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDim else { return image }
        let scale = maxDim / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
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
