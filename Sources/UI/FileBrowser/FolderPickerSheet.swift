import SwiftUI
import SwiftData
import KatafractStyle

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
                ForEach(flattenedFolders, id: \.folder.folderId) { entry in
                    Button {
                        onPick(entry.folder.folderId); dismiss()
                    } label: {
                        Label(entry.folder.name, systemImage: "folder.fill")
                            .foregroundStyle(Color.kataSapphire)
                            .padding(.leading, CGFloat(entry.depth) * 16)
                    }
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

    private struct FolderEntry {
        let folder: VaultFolder
        let depth: Int
    }

    private var flattenedFolders: [FolderEntry] {
        var result: [FolderEntry] = []
        let allowed = folders.filter { $0.folderId != excludeFolderId }
        let byParent: [String?: [VaultFolder]] = Dictionary(grouping: allowed) { $0.parentFolderId }

        func walk(parentId: String?, depth: Int) {
            let children = (byParent[parentId] ?? []).sorted { $0.name < $1.name }
            for child in children {
                result.append(FolderEntry(folder: child, depth: depth))
                walk(parentId: child.folderId, depth: depth + 1)
            }
        }
        walk(parentId: nil, depth: 0)
        return result
    }
}
