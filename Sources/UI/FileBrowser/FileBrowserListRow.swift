import SwiftUI
import KatafractStyle

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, @ViewBuilder transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

/// Extracted row helper for FileBrowserView list body.
/// 
/// Combines FileRowView + swipeActions + NavigationLink (for folders) in one
/// self-contained view to keep the type-checker happy and avoid inline body
/// complexity timeouts.
///
/// Handlers: onTap (files only), onRename, onDelete, onShare, onPin.
struct FileBrowserListRow: View {
    let item: VaultFileItem
    let isEditing: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onShare: () -> Void
    let onPin: () -> Void
    let onMove: () -> Void

    var body: some View {
        Group {
            if item.isFolder && !isEditing {
                // Folder row: NavigationLink owns the tap. Do NOT layer an
                // outer .onLongPressGesture here — it competes with the
                // NavigationLink's primary tap recognizer and can leave the
                // row "dead" to taps. Long-press to multiselect is a file-row
                // affordance only.
                NavigationLink {
                    FileBrowserView(folderId: item.id)
                } label: {
                    rowContent
                }
            } else {
                rowContent
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
                    .onLongPressGesture(perform: onLongPress)
            }
        }
        .if(!isEditing) { view in
            view
                .contextMenu {
                    Button(action: onShare) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button(action: onRename) {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(action: onMove) {
                        Label("Move", systemImage: "folder")
                    }
                    Button(action: onPin) {
                        Label(item.isPinned ? "Remove Offline" : "Keep Offline", systemImage: item.isPinned ? "pin.slash" : "pin")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
                    Button(action: onMove) {
                        Label("Move", systemImage: "folder")
                    }
                    .tint(Color.kataNavy)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button(action: onPin) {
                        Label(item.isPinned ? "Remove Offline" : "Keep Offline", systemImage: item.isPinned ? "pin.slash" : "pin")
                    }
                    .tint(Color.kataSapphire)
                }
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack {
            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .kataGold : .gray)
                    .padding(.trailing, 4)
            }
            FileRowView(
                item: item,
                onRename: { _ in onRename() },
                onDelete: onDelete,
                onShare: onShare,
                onPin: onPin
            )
        }
    }
}
