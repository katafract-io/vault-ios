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
    @State private var shareFile: VaultFileItem?
    @State private var shareURL: URL?
    @State private var selectedIds = Set<String>()
    @State private var isEditing = false
    @State private var previewURL: URL?
    @State private var previewTask: Task<Void, Never>?
    @State private var renameTarget: VaultFileItem?
    @State private var renamingName: String = ""
    @State private var showDeleteConfirmation = false
    @State private var fileLoadingStates: Set<String> = []
    @State private var moveTarget: VaultFileItem?
    @State private var showBulkMoveSheet = false
    @State private var selectedCategory: FileCategory = .all

    let folderId: String?  // nil = root

    enum ViewMode { case list, grid }
    enum SortOrder { case name, date, size, type }

    /// Materialize before presenting QuickLook. This keeps large downloads in
    /// the file browser with one stable progress banner instead of repeatedly
    /// rebuilding a loading sheet while progress updates arrive.
    private func beginPreview(_ item: VaultFileItem) {
        guard !fileLoadingStates.contains(item.id) else { return }
        fileLoadingStates.insert(item.id)
        previewTask?.cancel()
        previewURL = nil

        previewTask = Task { @MainActor in
            let url = await viewModel.materializeLocalURL(for: item)
            guard !Task.isCancelled else { return }
            if let url {
                previewURL = url
                selectedFile = item
            } else {
                fileLoadingStates.remove(item.id)
            }
            previewTask = nil
        }
    }

    private func cancelPreviewDownload() {
        previewTask?.cancel()
        previewTask = nil
        viewModel.cancelDownload()
        selectedFile = nil
        previewURL = nil
        fileLoadingStates.removeAll()
    }

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

    /// Bulk delete selected items and show Undo toast.
    private func bulkDelete() {
        let selectedItems = sortedItems.filter { selectedIds.contains($0.id) }
        guard !selectedItems.isEmpty else { return }

        var results: [FileBrowserViewModel.DeleteResult] = []
        for item in selectedItems {
            let result = viewModel.deleteItem(item)
            if !result.message.isEmpty {
                results.append(result)
            }
        }

        let message = "Deleted \(results.count) item\(results.count == 1 ? "" : "s")"
        let undoActions = results.map { $0.undo }

        undo.show(message: message) {
            for action in undoActions {
                await action()
            }
        }

        selectedIds.removeAll()
        isEditing = false
    }

    /// Bulk pin/unpin selected items.
    private func bulkTogglePin() {
        let selectedItems = sortedItems.filter { selectedIds.contains($0.id) }
        for item in selectedItems {
            viewModel.togglePin(item)
        }
        selectedIds.removeAll()
        isEditing = false
    }

    var sortedItems: [VaultFileItem] {
        let filtered: [VaultFileItem]
        if selectedCategory == .all {
            filtered = viewModel.items
        } else {
            filtered = viewModel.items.filter { item in
                item.isFolder || selectedCategory.matches(filename: item.name)
            }
        }
        let sorted: [VaultFileItem]
        switch sortOrder {
        case .name:
            sorted = filtered.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case .date:
            sorted = filtered.sorted { $0.modifiedAt > $1.modifiedAt }
        case .size:
            sorted = filtered.sorted { $0.sizeBytes > $1.sizeBytes }
        case .type:
            sorted = filtered.sorted { $0.isFolder && !$1.isFolder }
        }
        return sorted
    }

    var body: some View {
        Group {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                VStack(spacing: 0) {
                    if viewModel.uploadInProgress {
                        FileUploadProgressBanner(
                            fileIndex: viewModel.batchFileIndex,
                            totalFiles: viewModel.batchTotalFiles,
                            bytesUploaded: viewModel.batchBytesUploaded,
                            totalBytes: viewModel.batchTotalBytes,
                            onCancel: viewModel.cancelUpload
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if viewModel.downloadInProgress {
                        FileDownloadProgressBanner(
                            filename: viewModel.downloadFilename,
                            progress: viewModel.downloadProgress,
                            onCancel: cancelPreviewDownload
                        )
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                    }
                    EmptyFolderView(
                        onUpload: { gate { showUploadPicker = true } },
                        onUpgrade: subscriptionStore.isSubscribed ? nil : { showPaywall = true }
                    )
                }
                .animation(.spring(duration: 0.35), value: viewModel.uploadInProgress)
                .animation(nil, value: viewModel.downloadProgress)
                .animation(nil, value: viewModel.downloadInProgress)
            } else if viewMode == .list {
                listViewWithBanner
            } else {
                gridViewWithBanner
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isEditing && !selectedIds.isEmpty {
                HStack(spacing: 16) {
                    Button(action: { showDeleteConfirmation = true }) {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                    .foregroundColor(.red)

                    Spacer()

                    Button(action: { showBulkMoveSheet = true }) {
                        Image(systemName: "folder")
                        Text("Move")
                    }
                    .foregroundColor(.kataSapphire)

                    Spacer()

                    Button(action: { bulkTogglePin() }) {
                        Image(systemName: "pin")
                        Text("Keep Offline")
                    }
                    .foregroundColor(.kataGold)
                }
                .padding()
                .background(Color.kataNavy.opacity(0.95))
                .foregroundColor(.white)
            }
        }
        .overlay { UndoToast(model: undo) }
        .navigationTitle(isEditing && !selectedIds.isEmpty ? "\(selectedIds.count) selected" : viewModel.folderName)
        .confirmationDialog(
            "Delete \(selectedIds.count) item\(selectedIds.count == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirmation,
            actions: {
                Button("Delete", role: .destructive, action: bulkDelete)
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("This action cannot be undone.")
            }
        )
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                if isEditing {
                    Menu {
                        Button(action: {
                            let visibleIds = Set(sortedItems.map { $0.id })
                            selectedIds = visibleIds
                        }) {
                            Label("Select All", systemImage: "checkmark.circle")
                        }
                        Button(action: { selectedIds.removeAll() }) {
                            Label("Deselect All", systemImage: "circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isEditing {
                    Button(action: { isEditing = false; selectedIds.removeAll() }) {
                        Text("Done")
                    }
                } else {
                    Button(action: { gate { showNewFolder = true } }) {
                        Image(systemName: "folder.badge.plus")
                    }
                    Button(action: { gate { showUploadPicker = true } }) {
                        Image(systemName: "plus")
                    }
                    Button(action: { isEditing = true }) {
                        Image(systemName: "checkmark.circle")
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
        }
        .sheet(isPresented: $showUploadPicker) {
            DocumentPickerView(onPick: viewModel.uploadFiles)
        }
        .sheet(item: $moveTarget) { target in
            FolderPickerSheet(excludeFolderId: target.isFolder ? target.id : nil) { newParentId in
                viewModel.moveItem(target, to: newParentId)
            }
        }
        .sheet(isPresented: $showBulkMoveSheet) {
            FolderPickerSheet(excludeFolderId: nil) { newParentId in
                let selectedItems = sortedItems.filter { selectedIds.contains($0.id) }
                for item in selectedItems {
                    viewModel.moveItem(item, to: newParentId)
                }
                selectedIds.removeAll()
                isEditing = false
                showBulkMoveSheet = false
            }
        }
        .sheet(isPresented: $showPaywall) {
            CapacityPickerView()
        }
        .sheet(item: $selectedFile, onDismiss: {
            previewURL = nil
            fileLoadingStates.removeAll()
        }) { file in
            if let url = previewURL {
                FilePreviewSheet(fileURL: url, displayName: file.name)
            } else {
                FilePreviewLoadingSheet(displayName: file.name)
            }
        }
        .sheet(item: $shareFile, onDismiss: {
            shareURL = nil
        }) { file in
            if let url = shareURL {
                ActivityViewControllerWrapper(items: [url])
            } else {
                FilePreviewLoadingSheet(displayName: file.name)
                    .task {
                        if let url = await viewModel.materializeLocalURL(for: file) {
                            shareURL = url
                        } else {
                            shareFile = nil
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
        .onReceive(NotificationCenter.default.publisher(for: .vaultyxFileSynced)) { _ in
            viewModel.refreshFromCache()
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
    private var listViewWithBanner: some View {
        VStack(spacing: 0) {
            if viewModel.uploadInProgress {
                FileUploadProgressBanner(
                    fileIndex: viewModel.batchFileIndex,
                    totalFiles: viewModel.batchTotalFiles,
                    bytesUploaded: viewModel.batchBytesUploaded,
                    totalBytes: viewModel.batchTotalBytes,
                    onCancel: viewModel.cancelUpload
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if viewModel.downloadInProgress {
                FileDownloadProgressBanner(
                    filename: viewModel.downloadFilename,
                    progress: viewModel.downloadProgress,
                    onCancel: cancelPreviewDownload
                )
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
            CategoryFilterBar(selected: $selectedCategory)
            listView
        }
        .animation(.spring(duration: 0.35), value: viewModel.uploadInProgress)
        .animation(nil, value: viewModel.downloadProgress)
        .animation(nil, value: viewModel.downloadInProgress)
    }

    @ViewBuilder
    private var listView: some View {
        List {
            ForEach(sortedItems) { item in
                FileBrowserListRow(
                    item: item,
                    isEditing: isEditing,
                    isSelected: selectedIds.contains(item.id),
                    onTap: {
                        if isEditing {
                            if selectedIds.contains(item.id) {
                                selectedIds.remove(item.id)
                            } else {
                                selectedIds.insert(item.id)
                            }
                        } else {
                            beginPreview(item)
                        }
                    },
                    onLongPress: {
                        if !isEditing {
                            isEditing = true
                            selectedIds.insert(item.id)
                        }
                    },
                    onRename: { renameTarget = item; renamingName = item.name },
                    onDelete: { softDelete(item) },
                    onShare: { shareFile = item },
                    onPin: { viewModel.togglePin(item) },
                    onMove: { moveTarget = item }
                )
            }
        }
    }

    @ViewBuilder
    private var gridViewWithBanner: some View {
        VStack(spacing: 0) {
            if viewModel.uploadInProgress {
                FileUploadProgressBanner(
                    fileIndex: viewModel.batchFileIndex,
                    totalFiles: viewModel.batchTotalFiles,
                    bytesUploaded: viewModel.batchBytesUploaded,
                    totalBytes: viewModel.batchTotalBytes,
                    onCancel: viewModel.cancelUpload
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if viewModel.downloadInProgress {
                FileDownloadProgressBanner(
                    filename: viewModel.downloadFilename,
                    progress: viewModel.downloadProgress,
                    onCancel: cancelPreviewDownload
                )
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
            CategoryFilterBar(selected: $selectedCategory)
            gridView
        }
        .animation(.spring(duration: 0.35), value: viewModel.uploadInProgress)
        .animation(nil, value: viewModel.downloadProgress)
        .animation(nil, value: viewModel.downloadInProgress)
    }

    @ViewBuilder
    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 8)], spacing: 8) {
                ForEach(sortedItems) { item in
                    ZStack(alignment: .topTrailing) {
                        if item.isFolder && !isEditing {
                            NavigationLink {
                                FileBrowserView(folderId: item.id)
                            } label: {
                                GridItemView(item: item)
                            }
                            .buttonStyle(.plain)
                        } else {
                            GridItemView(item: item)
                                .onTapGesture {
                                    if isEditing {
                                        if selectedIds.contains(item.id) {
                                            selectedIds.remove(item.id)
                                        } else {
                                            selectedIds.insert(item.id)
                                        }
                                    } else if !item.isFolder {
                                        beginPreview(item)
                                    }
                                }
                                .onLongPressGesture {
                                    if !isEditing {
                                        isEditing = true
                                        selectedIds.insert(item.id)
                                    }
                                }
                        }
                        if isEditing {
                            Image(systemName: selectedIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedIds.contains(item.id) ? .kataGold : .gray)
                                .padding(8)
                        }
                    }
                }
            }
            .padding()
        }
    }
}


/// Simple wrapper for UIActivityViewController to share files.
struct ActivityViewControllerWrapper: UIViewControllerRepresentable {
    let items: [Any]
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            dismiss()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        FileBrowserView(folderId: nil)
    }
}
