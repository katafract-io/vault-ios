import SwiftUI
import KatafractStyle

/// Plain row view — intentionally NOT wrapped in a Button.
///
/// Why: when used as a NavigationLink's label, a Button wrapper inside the
/// label consumes the tap and prevents the NavigationLink from pushing.
/// Callers supply the tap target at the call site (NavigationLink for
/// folders, Button/onTapGesture for files).
///
/// Visual spec: 72pt row, 40×40 sapphire tile + filename + metadata line +
/// trailing gold lock-shield glyph (or upload/download pill when syncing).
/// Matches the "quietly expensive" tone of the paywall and Recovery Phrase.
struct FileRowView: View {
    let item: VaultFileItem
    var onRename: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onShare: () -> Void = {}
    var onPin: () -> Void = {}

    // Celebration state: when the sync transitions from uploading → synced
    // within this row's lifetime, flip to "sealed" for 1.5s then fall back
    // to the standard synced badge.
    @State private var sealedCelebration = false
    @State private var lastKnownState: VaultFileItem.SyncStateDisplay = .synced

    var body: some View {
        HStack(spacing: 12) {
            FileIconView(item: item)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.kataBody(16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.kataSapphire.opacity(0.75))
                    }
                    Text(metadataLine)
                        .font(.kataCaption(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            trailingBadge
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .onChange(of: item.syncState) { oldValue, newValue in
            handleSyncTransition(from: oldValue, to: newValue)
        }
        .contextMenu {
            Button(action: { onShare() }) {
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

    @ViewBuilder
    private var trailingBadge: some View {
        if sealedCelebration {
            UploadingPill(progress: 1, mode: .sealed)
                .transition(.scale.combined(with: .opacity))
        } else {
            SyncStatusBadge(state: item.syncState)
                .transition(.opacity)
        }
    }

    private var metadataLine: String {
        if item.isFolder {
            return "Folder · \(item.subtitle)"
        }
        let size = ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)
        let when = item.modifiedAt.formatted(.relative(presentation: .named))
        return "\(size) · \(when)"
    }

    private var accessibilityLabel: String {
        let pieces: [String] = [
            item.name,
            item.isFolder ? "folder" : "file",
            metadataLine,
            item.isPinned ? "pinned offline" : "",
            "encrypted"
        ].filter { !$0.isEmpty }
        return pieces.joined(separator: ", ")
    }

    private func handleSyncTransition(
        from old: VaultFileItem.SyncStateDisplay,
        to new: VaultFileItem.SyncStateDisplay
    ) {
        // Detect "uploading → synced" as the seal moment.
        if case .uploading = old, case .synced = new {
            KataHaptic.saved.fire()
            withAnimation(.spring(duration: 0.35, bounce: 0.3)) {
                sealedCelebration = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.35)) {
                    sealedCelebration = false
                }
            }
        }
        lastKnownState = new
    }
}

#Preview {
    List {
        FileRowView(
            item: VaultFileItem(
                id: "1",
                name: "Passport scan.pdf",
                isFolder: false,
                sizeBytes: 2_400_000,
                modifiedAt: Date().addingTimeInterval(-3600),
                syncState: .synced,
                isPinned: true
            )
        )
        FileRowView(
            item: VaultFileItem(
                id: "2",
                name: "Family Archive",
                isFolder: true,
                sizeBytes: 0,
                modifiedAt: Date().addingTimeInterval(-86400),
                syncState: .synced,
                isPinned: false
            )
        )
        FileRowView(
            item: VaultFileItem(
                id: "3",
                name: "Trip photos — Kyoto 2025.zip",
                isFolder: false,
                sizeBytes: 240_000_000,
                modifiedAt: Date(),
                syncState: .uploading(0.42),
                isPinned: false
            )
        )
    }
}
