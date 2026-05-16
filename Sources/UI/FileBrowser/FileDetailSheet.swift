import SwiftUI
import KatafractStyle

/// Modal sheet showing full file details with actions.
///
/// Layout:
/// - Header: file icon + name
/// - Details section: size, MIME type, created/modified dates
/// - CustodyBadge
/// - Keep Offline toggle (with current cache status)
/// - Actions: Move, Rename, Delete
///
/// Calls back to the parent via closures for each action.
struct FileDetailSheet: View {
    let item: VaultFileItem
    let isCached: Bool
    var onKeepOffline: () -> Void = {}
    var onMove: () -> Void = {}
    var onRename: () -> Void = {}
    var onDelete: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .center, spacing: 12) {
                        FileIconView(item: item)
                            .frame(width: 64, height: 64)

                        Text(item.name)
                            .font(.kataDisplay(20, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)

                        CustodyBadge(state: item.custodyState)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)

                    Divider()

                    // Details section
                    VStack(alignment: .leading, spacing: 16) {
                        DetailRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                        DetailRow(label: "Type", value: item.mimeType ?? "Unknown")
                        DetailRow(label: "Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        DetailRow(label: "Modified", value: item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    }

                    Divider()

                    // Keep Offline toggle
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Keep Offline", systemImage: isCached ? "cloud.fill" : "cloud.arrow.down")
                                .font(.kataBody(16, weight: .semibold))

                            Spacer()

                            if isCached {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.green)
                            }
                        }

                        if isCached {
                            Text("This file is cached for offline access.")
                                .font(.kataCaption(13))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Download and cache this file for offline access.")
                                .font(.kataCaption(13))
                                .foregroundStyle(.secondary)
                        }

                        Button(action: { onKeepOffline() }) {
                            Text(isCached ? "Remove from Offline" : "Make Available Offline")
                                .font(.kataBody(14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.kataSapphire)
                                .foregroundStyle(.white)
                                .cornerRadius(8)
                        }
                    }

                    Divider()

                    // Actions
                    if !item.isFolder {
                        VStack(spacing: 12) {
                            ActionButton(label: "Move", systemImage: "folder") {
                                onMove()
                                dismiss()
                            }

                            ActionButton(label: "Rename", systemImage: "pencil") {
                                onRename()
                                dismiss()
                            }

                            ActionButton(label: "Delete", systemImage: "trash", role: .destructive) {
                                onDelete()
                                dismiss()
                            }
                        }
                    }

                    Spacer(minLength: 20)
                }
                .padding(16)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.kataBody(14, weight: .semibold))
                }
            }
        }
    }
}

// MARK: - Components

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.kataCaption(12))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.kataBody(14, weight: .medium))
                .foregroundStyle(.primary)
        }
    }
}

private struct ActionButton: View {
    let label: String
    let systemImage: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(label, systemImage: systemImage)
                .font(.kataBody(14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(role == .destructive ? .red : .kataSapphire)
        }
    }
}

// MARK: - Preview

#Preview {
    var item = VaultFileItem(
        id: "test-doc",
        name: "Tax Return 2024.pdf",
        isFolder: false,
        sizeBytes: 1_500_000,
        modifiedAt: Date().addingTimeInterval(-86400),
        syncState: .synced,
        isPinned: false
    )
    item.custodyState = .inVault
    item.mimeType = "application/pdf"
    item.createdAt = Date().addingTimeInterval(-604800)

    return FileDetailSheet(item: item, isCached: false)
}
