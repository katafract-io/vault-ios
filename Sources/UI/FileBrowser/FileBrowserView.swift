import SwiftUI
import SwiftData

struct FileBrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var services: VaultServices
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @StateObject private var viewModel = FileBrowserViewModel()
    @StateObject private var undo = UndoToastModel()
    @State private var viewMode: ViewMode = .list
    @State private var sortOrder: SortOrder = .name
    @State private var showUploadPicker = false
    @State private var showNewFolder = false
    @State private var showPaywall = false
    @State private var selectedFile: VaultFileItem?
    @State private var previewURL: URL?
    @State private var renameTarget: VaultFileItem?
    @State private var renamingName: String = ""

    let folderId: String?  // nil = root

    enum ViewMode { case list, grid }
    enum SortOrder { case name, date, size, type }

    /// Gate a write-side action behind the Sovereign subscription. If the
    /// user is a subscriber, the action runs immediately; otherwise the
    /// paywall is presented.
    private func gate(_ action: () -> Void) {
        if subscriptionStore.isSubscribed {
            action()
        } else {
            showPaywall = true
        }
    }

    /// Delete an item and surface an Undo toast. The VM handles the server
    /// and local-cache mutations; the toast holds the reverse action for 6
    /// seconds and routes it back through the VM on tap.
    private func softDelete(_ item: VaultFileItem) {
        let result = viewModel.deleteItem(item)
        guard !result.message.isEmpty else { return }
        undo.show(message: result.message, onUndo: result.undo)
    }

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
        .overlay { UndoToast(model: undo) }
        .navigationTitle(viewModel.folderName)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: { gate { showNewFolder = true } }) {
                    Image(systemName: "folder.badge.plus")
                }
                Button(action: { gate { showUploadPicker = true } }) {
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
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .sheet(item: $selectedFile, onDismiss: { previewURL = nil }) { file in
            if let url = previewURL {
                FilePreviewSheet(fileURL: url, displayName: file.name)
            } else {
                FilePreviewLoadingSheet(displayName: file.name)
                    .task {
                        let url = await viewModel.materializeLocalURL(for: file)
                        if let url {
                            previewURL = url
                        } else {
                            // Dismiss the sheet; the error alert below will
                            // surface the reason via viewModel.error.
                            selectedFile = nil
                        }
                    }
            }
        }
        .alert("Can't open file",
               isPresented: Binding(
                   get: { viewModel.error != nil },
                   set: { if !$0 { viewModel.error = nil } }),
               presenting: viewModel.error) { _ in
            Button("OK") { viewModel.error = nil }
        } message: { err in
            Text(err)
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
            viewModel.configure(services: services)
            await viewModel.load(folderId: folderId)
        }
        .refreshable {
            // Pull-to-refresh: run the full sync inline (user-initiated, so
            // we can block the spinner on the network round-trip) rather
            // than the fire-and-forget pattern `load` uses.
            do {
                try await VaultTreeSync(services: services).sync()
            } catch {
                viewModel.error = "Sync failed: \(error.localizedDescription)"
            }
            await viewModel.load(folderId: folderId)
        }
    }

    @ViewBuilder
    private var listView: some View {
        List {
            ForEach(sortedItems) { item in
                if item.isFolder {
                    NavigationLink {
                        FileBrowserView(folderId: item.id)
                    } label: {
                        FileRowView(
                            item: item,
                            onRename: { _ in
                                renameTarget = item
                                renamingName = item.name
                            },
                            onDelete: { softDelete(item) },
                            onPin: { viewModel.togglePin(item) }
                        )
                    }
                } else {
                    FileRowView(
                        item: item,
                        onRename: { _ in
                            renameTarget = item
                            renamingName = item.name
                        },
                        onDelete: { softDelete(item) },
                        onPin: { viewModel.togglePin(item) }
                    )
                    .onTapGesture { selectedFile = item }
                }
            }
        }
    }

    @ViewBuilder
    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 8)], spacing: 8) {
                ForEach(sortedItems) { item in
                    if item.isFolder {
                        NavigationLink {
                            FileBrowserView(folderId: item.id)
                        } label: {
                            GridItemView(item: item)
                        }
                        .buttonStyle(.plain)
                    } else {
                        GridItemView(item: item)
                            .onTapGesture { selectedFile = item }
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
