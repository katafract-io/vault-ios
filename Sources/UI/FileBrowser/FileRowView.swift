import SwiftUI

/// Plain row view — intentionally NOT wrapped in a Button.
///
/// Why: when used as a NavigationLink's label, a Button wrapper inside the
/// label consumes the tap and prevents the NavigationLink from pushing.
/// Callers supply the tap target at the call site (NavigationLink for
/// folders, Button/onTapGesture for files).
struct FileRowView: View {
    let item: VaultFileItem
    var onRename: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onShare: () -> Void = {}
    var onPin: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            FileIconView(item: item)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            SyncStatusBadge(state: item.syncState)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: onShare) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button(action: onPin) {
                Label(item.isPinned ? "Unpin" : "Keep Offline",
                      systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            Divider()
            Button(action: { onRename(item.name) }) {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

#Preview {
    List {
        FileRowView(
            item: VaultFileItem(
                id: "1",
                name: "document.pdf",
                isFolder: false,
                sizeBytes: 2_400_000,
                modifiedAt: Date().addingTimeInterval(-3600),
                syncState: .synced,
                isPinned: true
            )
        )
    }
}
