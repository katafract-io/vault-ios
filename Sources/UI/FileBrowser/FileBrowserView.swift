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
    @State private var uploadSource: UploadSource?
    @State private var showDocumentPicker = false
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @State private var showScanStub = false
    @State private var showNewFolder = false
    @State private var showPaywall = false
    @State private var selectedFile: VaultFileItem?
    @State private var shareFile: VaultFileItem?
    @State private var shareURL: URL?
    @State private var selectedIds = Set<String>()
    @State private var isEditing = false
    @State private var previewURL: URL?
    @State private var previewIsLoading = false
    @State private var previewError: String?
    @State private var renameTarget: VaultFileItem?
    @State private var renamingName: String = ""
    @State private var showDeleteConfirmation = false
    @State private var fileLoadingStates: Set<String> = []
    @State private var moveTarget: VaultFileItem?
    @State private var showBulkMoveSheet = false
    @State private var selectedCategory: FileCategory = .all
    @State private var pendingInboxCount: Int = 0
    @State private var showStuckItems = false

    let folderId: String?  // nil = root
    var isReadOnly: Bool = false

    enum ViewMode { case list, grid }
    enum SortOrder { case name, date, size, type }

    /// Gate a write-side action behind the Sovereign subscription. If the
    /// user is a subscriber, the action runs immediately; otherwise the
    /// paywall is presented.
    private var breadcrumbPath: [BreadcrumbItem] {
        var path: [BreadcrumbItem] = [.init(name: "Vault", item: nil)]
        for item in viewModel.navPath {
            path.append(.init(name: item.name, item: item))
        }
        return path
    }

    private func navigateToBreadcrumb(_ index: Int) {
        if index == 0 {
            viewModel.navPath.removeAll()
        } else {
            viewModel.navPath = Array(viewModel.navPath.prefix(index))
        }
    }

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

    /// Bulk star/unstar selected items.
    private func bulkToggleStar() {
        let selectedItems = sortedItems.filter { selectedIds.contains($0.id) }
        for item in selectedItems {
            viewModel.toggleStar(item)
        }
        selectedIds.removeAll()
        isEditing = false
    }

    /// Bulk toggle offline mode for selected items.
    private func bulkToggleOffline() {
        let selectedItems = sortedItems.filter { selectedIds.contains($0.id) }
        for item in selectedItems {
            viewModel.toggleOffline(item)
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
            sorted = filtered.sorted { a, b in
                if a.isFolder != b.isFolder {
                    return a.isFolder && !b.isFolder
                }
                return a.name.lowercased() < b.name.lowercased()
            }
        case .date:
            sorted = filtered.sorted { a, b in
                if a.isFolder != b.isFolder {
                    return a.isFolder && !b.isFolder
                }
                return a.modifiedAt > b.modifiedAt
            }
        case .size:
            sorted = filtered.sorted { a, b in
                if a.isFolder != b.isFolder {
                    return a.isFolder && !b.isFolder
                }
                return a.sizeBytes > b.sizeBytes
            }
        case .type:
            sorted = filtered.sorted { a, b in
                if a.isFolder != b.isFolder {
                    return a.isFolder && !b.isFolder
                }
                return a.name.lowercased() < b.name.lowercased()
            }
        }
        return sorted
    }

    @ViewBuilder
    private var stuckItemsBanner: some View {
        if viewModel.stuckCount > 0 {
            Button(action: { showStuckItems = true }) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamation.circle.fill")
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.stuckCount == 1 ? "1 upload failed" : "\(viewModel.stuckCount) uploads failed")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Tap to fix")
                            .font(.system(size: 12))
                            .opacity(0.85)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.red)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    var body: some View {
        NavigationStack(path: $viewModel.navPath) {
            VStack(spacing: 0) {
                // Breadcrumb navigation
                if !viewModel.navPath.isEmpty {
                    BreadcrumbNavigation(path: breadcrumbPath) { index in
                        navigateToBreadcrumb(index)
                    }
                    .padding(.vertical, 8)
                    Divider()
                }

                // Single banner instance — hoisting outside the branch selector
                // prevents the spring transition from re-firing when items.isEmpty
                // or viewMode flips (which would swap branches, animating the
                // banner out and back in on every state change).
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
                        onCancel: { viewModel.cancelDownload(); selectedFile = nil }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if pendingInboxCount > 0 {
                    PendingShareBanner(count: pendingInboxCount) {
                        Task {
                            await services.drainShareExtensionInbox()
                            pendingInboxCount = services.pendingInboxCount()
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                stuckItemsBanner
                if viewModel.items.isEmpty && !viewModel.isLoading {
                    EmptyFolderView(
                        onUpload: { gate { uploadSource = .files } },
                        onUpgrade: subscriptionStore.isSubscribed ? nil : { showPaywall = true }
                    )
                } else if viewMode == .list {
                    listContent
                } else {
                    gridContent
                }
            }
            .navigationDestination(for: VaultFileItem.self) { item in
                FileBrowserView(folderId: item.id)
            }
            .navigationDestination(isPresented: $showStuckItems) {
                StuckItemsView()
            }
        }
        .animation(.spring(duration: 0.35), value: viewModel.uploadInProgress)
        .animation(.spring(duration: 0.35), value: viewModel.downloadInProgress)
        .safeAreaInset(edge: .bottom) {
            if isEditing && !selectedIds.isEmpty {
                VStack(spacing: 0) {
                    Divider()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 24) {
                            Button(action: { showDeleteConfirmation = true }) {
                                VStack(spacing: 4) {
                                    Image(systemName: "trash")
                                    Text("Delete")
                                        .font(.caption)
                                }
                            }
                            .foregroundColor(.red)

                            Button(action: { showBulkMoveSheet = true }) {
                                VStack(spacing: 4) {
                                    Image(systemName: "folder")
                                    Text("Move")
                                        .font(.caption)
                                }
                            }
                            .foregroundColor(.kataSapphire)

                            Button(action: { bulkToggleStar() }) {
                                VStack(spacing: 4) {
                                    Image(systemName: "star")
                                    Text("Star")
                                        .font(.caption)
                                }
                            }
                            .foregroundColor(.kataGold)

                            Button(action: { bulkToggleOffline() }) {
                                VStack(spacing: 4) {
                                    Image(systemName: "pin")
                                    Text("Offline")
                                        .font(.caption)
                                }
                            }
                            .foregroundColor(.kataGold)

                            Spacer()
                                .frame(width: 1)
                        }
                        .padding()
                    }
                }
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
                    Button(action: { gate { uploadSource = .files } }) {
                        Image(systemName: "plus")
                    }
                    .disabled(isReadOnly)
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
        .confirmationDialog(
            "Add Files",
            isPresented: Binding(
                get: { uploadSource != nil },
                set: { if !$0 { uploadSource = nil } }),
            presenting: uploadSource) { source in
            Button(action: {
                showScanStub = true
                uploadSource = nil
            }) {
                Label("Scan Document", systemImage: "doc.viewfinder")
            }
            Button(action: {
                showCameraPicker = true
                uploadSource = nil
            }) {
                Label("Take Photo", systemImage: "camera")
            }
            Button(action: {
                showPhotoPicker = true
                uploadSource = nil
            }) {
                Label("Choose Photos", systemImage: "photo.on.rectangle")
            }
            Button(action: {
                showDocumentPicker = true
                uploadSource = nil
            }) {
                Label("Choose Files", systemImage: "folder")
            }
            Button("Cancel", role: .cancel) {
                uploadSource = nil
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView(onPick: viewModel.uploadFiles)
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerView(onPick: viewModel.uploadFiles)
        }
        .sheet(isPresented: $showCameraPicker) {
            CameraPickerView(onPick: viewModel.uploadFiles)
        }
        .sheet(isPresented: $showScanStub) {
            VStack(spacing: 16) {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 48))
                    .foregroundColor(.kataSapphire)
                Text("Coming Soon")
                    .font(.headline)
                Text("Document scanning will be available soon.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button("OK") {
                    showScanStub = false
                    uploadSource = nil
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.kataSapphire)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .padding()
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
            previewIsLoading = false
            previewError = nil
            // selectedFile is already nil here (that's what triggered dismiss).
            // Clear all loading states — the tap guard below blocks re-entry
            // during an in-flight materialize, but on dismiss we're done.
            fileLoadingStates.removeAll()
        }) { file in
            FilePreviewSheet(
                displayName: file.name,
                fileURL: previewURL,
                errorMessage: previewError
            )
            .onAppear {
                guard !previewIsLoading else { return }
                previewIsLoading = true
                previewError = nil

                Task {
                    let url = await viewModel.materializeLocalURL(for: file)
                    if let url {
                        previewURL = url
                    } else {
                        previewError = viewModel.error
                            ?? "The file isn't available right now."
                        viewModel.error = nil
                        fileLoadingStates.remove(file.id)
                    }
                    previewIsLoading = false
                }
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
            pendingInboxCount = services.pendingInboxCount()
            viewModel.refreshStuckCount()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                pendingInboxCount = services.pendingInboxCount()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultyxFileSynced)) { _ in
            // Drain worker just confirmed a manifest. Refresh so the row's
            // sync badge transitions from .pendingUpload → .synced without
            // waiting for the user to navigate away and back.
            viewModel.refreshFromCache()
            // stuckCount is updated within refreshFromCache
        }
        #if targetEnvironment(macCatalyst)
        .onReceive(NotificationCenter.default.publisher(for: .vaultNewFolder)) { _ in
            gate { showNewFolder = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultFindActivated)) { _ in
            // Placeholder for Find functionality — toggle search UI when implemented
            dlog("Find activated", category: "mac")
        }
        #endif
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
            viewModel.refreshStuckCount()
        }
    }

    @ViewBuilder
    private var listContent: some View {
        VStack(spacing: 0) {
            CategoryFilterBar(selected: $selectedCategory)
            listView
        }
    }

    @ViewBuilder
    private var listView: some View {
        List {
            ForEach(sortedItems) { item in
                ZStack {
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
                            } else if item.isFolder {
                                viewModel.navPath.append(item)
                            } else if !fileLoadingStates.contains(item.id) {
                                // Guard: prevent re-entry while materialize is in
                                // flight. Without this, an impatient user tapping
                                // multiple times starts parallel downloads of the
                                // same file and the cell flashes repeatedly.
                                fileLoadingStates.insert(item.id)
                                selectedFile = item
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
                        onMove: { moveTarget = item },
                        onDuplicate: { viewModel.duplicateItem(item) },
                        onToggleStar: { viewModel.toggleStar(item) },
                        onToggleOffline: { viewModel.toggleOffline(item) }
                    )
                    if item.isFolder && !isEditing {
                        NavigationLink(value: item) { EmptyView() }
                            .opacity(0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        VStack(spacing: 0) {
            CategoryFilterBar(selected: $selectedCategory)
            gridView
        }
    }

    @ViewBuilder
    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 8)], spacing: 8) {
                ForEach(sortedItems) { item in
                    ZStack(alignment: .topTrailing) {
                        GridItemView(item: item)
                            .onTapGesture {
                                if isEditing {
                                    if selectedIds.contains(item.id) {
                                        selectedIds.remove(item.id)
                                    } else {
                                        selectedIds.insert(item.id)
                                    }
                                } else if item.isFolder {
                                    viewModel.navPath.append(item)
                                } else if !fileLoadingStates.contains(item.id) {
                                    // Same re-entry guard as list view.
                                    fileLoadingStates.insert(item.id)
                                    selectedFile = item
                                }
                            }
                            .onLongPressGesture {
                                if !isEditing {
                                    isEditing = true
                                    selectedIds.insert(item.id)
                                }
                            }
                        if item.isFolder && !isEditing {
                            NavigationLink(value: item) { EmptyView() }
                                .opacity(0)
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


struct BreadcrumbItem {
    let name: String
    let item: VaultFileItem?
}

/// Breadcrumb navigation view — shows path as tappable chips
struct BreadcrumbNavigation: View {
    let path: [BreadcrumbItem]
    let onTap: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(path.enumerated()), id: \.offset) { index, breadcrumb in
                    Button(action: { onTap(index) }) {
                        HStack(spacing: 4) {
                            Text(breadcrumb.name)
                                .font(.kataCaption(12))
                                .lineLimit(1)
                            if index < path.count - 1 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8))
                            }
                        }
                        .foregroundColor(.kataSapphire)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.kataSapphire.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
            }
            .padding(.horizontal)
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
