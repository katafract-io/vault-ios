import SwiftUI
import KatafractStyle

/// Extracted row helper for FileBrowserView list body.
/// 
/// Combines FileRowView + swipeActions + NavigationLink (for folders) in one
/// self-contained view to keep the type-checker happy and avoid inline body
/// complexity timeouts.
///
/// Handlers: onTap (files only), onRename, onDelete, onShare, onPin.
struct FileBrowserListRow: View {
    let item: VaultFileItem
    let onTap: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onShare: () -> Void
    let onPin: () -> Void

    var body: some View {
        Group {
            if item.isFolder {
                NavigationLink {
                    FileBrowserView(folderId: item.id)
                } label: {
                    FileRowView(
                        item: item,
                        onRename: { _ in onRename() },
                        onDelete: onDelete,
                        onShare: onShare,
                        onPin: onPin
                    )
                }
            } else {
                FileRowView(
                    item: item,
                    onRename: { _ in onRename() },
                    onDelete: onDelete,
                    onShare: onShare,
                    onPin: onPin
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            Button(action: onShare) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(Color.kataGold)
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            .tint(Color.kataSapphire)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(action: onPin) {
                Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            .tint(Color.kataSapphire)
        }
    }
}
