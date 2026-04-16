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

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                if let thumb = item.thumbnailImage {
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
