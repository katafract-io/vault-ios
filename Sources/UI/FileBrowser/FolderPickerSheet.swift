import SwiftUI
import SwiftData

struct FolderPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var folders: [VaultFolder]
    let excludeFolderId: String?
    let onPick: (String?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onPick(nil); dismiss()
                } label: {
                    Label("Root", systemImage: "house.fill")
                        .foregroundStyle(Color.kataGold)
                }
                ForEach(rootFolders, id: \.folderId) { f in
                    folderRow(f, depth: 0)
                }
            }
            .navigationTitle("Move to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var rootFolders: [VaultFolder] {
        folders.filter { \/bin/bash.parentFolderId == nil && \/bin/bash.folderId != excludeFolderId }
            .sorted { \/bin/bash.name < \.name }
    }

    private func childrenOf(_ parentId: String) -> [VaultFolder] {
        folders.filter { \/bin/bash.parentFolderId == parentId && \/bin/bash.folderId != excludeFolderId }
            .sorted { \/bin/bash.name < \.name }
    }

    @ViewBuilder
    private func folderRow(_ folder: VaultFolder, depth: Int) -> some View {
        let kids = childrenOf(folder.folderId)
        if kids.isEmpty {
            Button { onPick(folder.folderId); dismiss() } label: {
                Label(folder.name, systemImage: "folder.fill")
                    .foregroundStyle(Color.kataSapphire)
                    .padding(.leading, CGFloat(depth) * 16)
            }
        } else {
            DisclosureGroup {
                ForEach(kids, id: \.folderId) { c in folderRow(c, depth: depth + 1) }
            } label: {
                Button { onPick(folder.folderId); dismiss() } label: {
                    Label(folder.name, systemImage: "folder.fill")
                        .foregroundStyle(Color.kataSapphire)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, CGFloat(depth) * 16)
        }
    }
}
