import SwiftUI
import SwiftData

struct FileBrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = FileBrowserViewModel()
    @State private var viewMode: ViewMode = .list
    @State private var sortOrder: SortOrder = .name
    @State private var showUploadPicker = false
    @State private var showNewFolder = false
    @State private var selectedFile: VaultFileItem?
    @State private var renameTarget: VaultFileItem?
    @State private var renamingName: String = ""

    let folderId: String?  // nil = root

    enum ViewMode { case list, grid }
    enum SortOrder { case name, date, size, type }

    var sortedItems: [VaultFileItem] {
        let sorted: [VaultFileItem]
        switch sortOrder {
        case .name:
            sorted = viewModel.items.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case .date:
            sorted = viewModel.items.sorted { $0.modifiedAt > $1.modifiedAt }
        case .size:
            sorted = viewModel.items.sorted { $0.sizeBytes > $1.sizeBytes }
        case .type:
            sorted = viewModel.items.sorted { $0.isFolder && !$1.isFolder }
        }
        return sorted
    }

    var body: some View {
        Group {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                EmptyFolderView(onUpload: { showUploadPicker = true })
            } else if viewMode == .list {
                listView
            } else {
                gridView
            }
        }
        .navigationTitle(viewModel.folderName)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: { showNewFolder = true }) {
                    Image(systemName: "folder.badge.plus")
                }
                Button(action: { showUploadPicker = true }) {
                    Image(systemName: "plus")
                }
                Menu {
                    Picker("View", selection: $viewMode) {
                        Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                        Label("Grid", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                    }
                    Divider()
                    Picker("Sort", selection: $sortOrder) {
                        Text("Name").tag(SortOrder.name)
                        Text("Date").tag(SortOrder.date)
                        Text("Size").tag(SortOrder.size)
                        Text("Type").tag(SortOrder.type)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showUploadPicker) {
            DocumentPickerView(onPick: viewModel.uploadFiles)
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            NewFolderAlert(onCreate: viewModel.createFolder)
        }
        .alert("Rename", isPresented: .constant(renameTarget != nil)) {
            TextField("New name", text: $renamingName)
            Button("Rename") {
                if let target = renameTarget, !renamingName.isEmpty {
                    viewModel.renameItem(target, newName: renamingName)
                }
                renameTarget = nil
                renamingName = ""
            }
            Button("Cancel", role: .cancel) {
                renameTarget = nil
                renamingName = ""
            }
        }
        .task {
            await viewModel.load(folderId: folderId)
        }
        .refreshable {
            await viewModel.load(folderId: folderId)
        }
    }

    @ViewBuilder
    private var listView: some View {
        List {
            ForEach(sortedItems) { item in
                FileRowView(
                    item: item,
                    onRename: { _ in
                        renameTarget = item
                        renamingName = item.name
                    },
                    onDelete: {
                        viewModel.deleteItem(item)
                    },
                    onShare: {
                        // TODO: share action
                    },
                    onPin: {
                        viewModel.togglePin(item)
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 8)], spacing: 8) {
                ForEach(sortedItems) { item in
                    GridItemView(item: item)
                        .onTapGesture {
                            selectedFile = item
                        }
                }
            }
            .padding()
        }
    }
}

#Preview {
    NavigationStack {
        FileBrowserView(folderId: nil)
    }
}
