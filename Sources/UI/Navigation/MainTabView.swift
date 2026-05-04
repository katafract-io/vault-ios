import SwiftUI
import KatafractStyle
import SwiftData

struct MainTabView: View {
    @ObservedObject private var lock = BiometricLock.shared

    var body: some View {
        TabView {
            NavigationStack {
                FileBrowserView(folderId: nil)
            }
            .tabItem {
                Label("Files", systemImage: "folder.fill")
            }

            NavigationStack {
                PhotosView()
            }
            .tabItem {
                Label("Photos", systemImage: "photo.fill")
            }

            NavigationStack {
                RecentsView()
            }
            .tabItem {
                Label("Recent", systemImage: "clock.fill")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
        .tint(.kataSapphire)
    }
}

// MARK: - Recents View

struct RecentsView: View {
    @EnvironmentObject private var services: VaultServices
    @StateObject private var viewModel = RecentsViewModel()
    @State private var selectedFile: VaultFileItem?
    @State private var previewURL: URL?
    @State private var previewError: String?

    var body: some View {
        Group {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("No Recent Files", systemImage: "clock")
                } description: {
                    Text("Files you open will appear here")
                }
            } else if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.items) { item in
                        FileRowView(
                            item: item,
                            onDelete: { viewModel.deleteItem(item) },
                            onPin: { viewModel.togglePin(item) }
                        )
                        .onTapGesture { selectedFile = item }
                    }
                }
            }
        }
        .navigationTitle("Recent")
        .sheet(item: $selectedFile, onDismiss: {
            previewURL = nil
            previewError = nil
        }) { file in
            FilePreviewSheet(
                displayName: file.name,
                fileURL: previewURL,
                errorMessage: previewError
            )
            .task(id: file.id) {
                guard previewURL == nil, previewError == nil else { return }
                let url = await viewModel.materializeLocalURL(for: file)
                if let url {
                    previewURL = url
                } else {
                    previewError = viewModel.error
                        ?? "The file isn't available right now."
                    viewModel.error = nil
                }
            }
        }
        .task {
            viewModel.configure(services: services)
            await viewModel.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultyxFileSynced)) { _ in
            Task { await viewModel.load() }
        }
        .refreshable {
            await viewModel.load()
        }
    }
}

@MainActor
class RecentsViewModel: ObservableObject {
    @Published var items: [VaultFileItem] = []
    @Published var isLoading = false
    @Published var error: String?

    private weak var services: VaultServices?

    func configure(services: VaultServices) {
        self.services = services
    }

    /// Build the Recents list from the union of local SwiftData rows and the
    /// server's recents response. Local rows surface in-flight uploads (which
    /// the server hasn't seen yet), so a freshly-imported file appears here
    /// immediately instead of waiting on the drain to finalize.
    func load() async {
        isLoading = true
        defer { isLoading = false }

        if ScreenshotMode.seedData != nil {
            injectSeedRecentFiles()
            return
        }

        guard let services else {
            items = []
            return
        }

        // Local cache rows — already have the plaintext filename and live
        // syncState. Sorted newest-first; capped at 20 to match the server.
        let context = ModelContext(services.modelContainer)
        let localRows = ((try? context.fetch(FetchDescriptor<LocalFile>())) ?? [])
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(20)

        var merged: [VaultFileItem] = []
        var seenIds = Set<String>()
        for row in localRows {
            seenIds.insert(row.fileId)
            merged.append(VaultFileItem(
                id: row.fileId,
                name: row.filename,
                isFolder: false,
                sizeBytes: row.sizeBytes,
                modifiedAt: row.modifiedAt,
                syncState: Self.displayState(for: row.syncState),
                isPinned: row.isPinned))
        }

        // Server response — decrypt filenames against the file's folder key
        // (recents include files from any folder, so each file may need its
        // own key). Skip records the local cache already covers.
        do {
            let response = try await services.apiClient.listRecentFiles(limit: 20)
            for record in response.files where !seenIds.contains(record.file_id) {
                let folderId = record.parent_folder_id ?? "root"
                let displayName: String
                do {
                    let folderKey = try await services.keyManager.getOrCreateFolderKey(folderId: folderId)
                    displayName = try services.syncEngine.decryptFilename(record.filename_enc, folderKey: folderKey)
                } catch {
                    displayName = "Encrypted file"
                }
                merged.append(VaultFileItem(
                    id: record.file_id,
                    name: displayName,
                    isFolder: false,
                    sizeBytes: record.size_bytes,
                    modifiedAt: Date(timeIntervalSince1970: TimeInterval(record.modified_at)),
                    syncState: .synced,
                    isPinned: false))
            }
        } catch {
            // Local rows still display; surface the network error only if there
            // are no local rows either, otherwise the user sees a stale-but-
            // useful list rather than an empty pane.
            if merged.isEmpty {
                self.error = "Failed to load recent files: \(error.localizedDescription)"
            }
        }

        merged.sort { $0.modifiedAt > $1.modifiedAt }
        items = Array(merged.prefix(20))
    }

    private static func displayState(for raw: String) -> VaultFileItem.SyncStateDisplay {
        switch raw {
        case "pending_upload": return .pendingUpload
        case "partial":        return .partial
        case "uploading":      return .uploading(0)
        case "downloading":    return .downloading(0)
        case "conflict":       return .conflict
        default:               return .synced
        }
    }

    /// Soft-delete a recents row. Mirrors FileBrowserViewModel.deleteItem's
    /// network + local cleanup so the row disappears immediately.
    func deleteItem(_ item: VaultFileItem) {
        guard let services else { return }
        items.removeAll { $0.id == item.id }
        let context = ModelContext(services.modelContainer)
        Task { @MainActor in
            do {
                try await services.apiClient.softDeleteFile(fileId: item.id)
                if let rows = try? context.fetch(FetchDescriptor<LocalFile>()) {
                    for row in rows where row.fileId == item.id {
                        context.delete(row)
                    }
                    try? context.save()
                }
            } catch {
                self.error = "Delete failed: \(error.localizedDescription)"
            }
        }
    }

    private func injectSeedRecentFiles() {
        items = [
            VaultFileItem(
                id: UUID().uuidString.lowercased(),
                name: "2024 W-2.pdf",
                isFolder: false,
                sizeBytes: 145 * 1024,
                modifiedAt: Date(timeIntervalSinceNow: -3600),
                syncState: .synced,
                isPinned: false
            ),
            VaultFileItem(
                id: UUID().uuidString.lowercased(),
                name: "Driver License.heic",
                isFolder: false,
                sizeBytes: 2_100 * 1024,
                modifiedAt: Date(timeIntervalSinceNow: -7200),
                syncState: .synced,
                isPinned: true
            ),
            VaultFileItem(
                id: UUID().uuidString.lowercased(),
                name: "Mortgage Notes.docx",
                isFolder: false,
                sizeBytes: 87 * 1024,
                modifiedAt: Date(timeIntervalSinceNow: -10800),
                syncState: .synced,
                isPinned: false
            ),
        ]
    }

    func materializeLocalURL(for item: VaultFileItem) async -> URL? {
        guard let services else {
            error = "VaultServices not configured"
            return nil
        }
        do {
            let folderKey = try await services.keyManager.getOrCreateFolderKey(folderId: "root")
            let plaintext = try await services.syncEngine.downloadFile(
                fileId: item.id, folderKey: folderKey)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension((item.name as NSString).pathExtension)
            try plaintext.write(to: tmp, options: .atomic)
            return tmp
        } catch {
            self.error = "Couldn't open \(item.name): \(error.localizedDescription)"
            return nil
        }
    }

    func togglePin(_ item: VaultFileItem) {
        guard let services else { return }
        let context = ModelContext(services.modelContainer)
        let descriptor = FetchDescriptor<LocalFile>()
        if let rows = try? context.fetch(descriptor) {
            for row in rows where row.fileId == item.id {
                row.isPinned.toggle()
            }
            try? context.save()
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject private var lock = BiometricLock.shared
    @EnvironmentObject private var services: VaultServices
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var vaultMeta: VaultMetaResponse?
    @State private var usedBytes: Int64 = -1
    @State private var showPhrase = false
    @State private var showRestore = false
    @State private var showPaywall = false
    @State private var pendingCount: Int = 0
    @State private var pendingBytes: Int64 = 0
    @State private var isDraining = false
    @State private var confirmClearQueue = false

    private let sovereignQuota: Int64 = 1_099_511_627_776  // 1 TiB

    var body: some View {
        List {
            StorageQuotaView(usedBytes: vaultMeta?.usage_bytes ?? usedBytes, totalBytes: vaultMeta?.quota_bytes ?? sovereignQuota)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

            // MARK: Upgrade CTA — visible to non-subscribers (path A for Apple review)
            if !subscriptionStore.isSubscribed {
                Section {
                    Button {
                        KataHaptic.revealed.fire()
                        showPaywall = true
                    } label: {
                        Text("Upgrade to Sovereign — 7-day free trial")
                            .font(.kataHeadline(17, weight: .medium))
                            .foregroundStyle(Color.kataIce)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.kataSapphire)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            Section {
                if subscriptionStore.isSubscribed {
                    settingsRow(icon: "person.crop.circle.fill", title: "Plan", value: "Sovereign")
                    settingsRow(icon: "externaldrive.fill", title: "Storage", value: storageDisplayLabel())
                } else {
                    settingsRow(icon: "person.crop.circle.fill", title: "Plan", value: "Free")
                }
            } header: {
                sectionHeader("Account")
            }

            Section {
                heroRecoveryRow

                settingsButtonRow(
                    icon: "key.horizontal.fill",
                    title: "Restore from Recovery Phrase",
                    action: { showRestore = true }
                )

                HStack(spacing: 12) {
                    Image(systemName: "faceid")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.kataSapphire)
                        .frame(width: 28)
                    Toggle("Biometric Lock", isOn: $lock.isEnabled)
                        .tint(.kataSapphire)
                        .font(.kataBody(15))
                }
                .listRowBackground(Color.kataSapphire.opacity(0.04))
            } header: {
                sectionHeader("Security")
            }

            Section {
                NavigationLink {
                    RecycleBinView()
                } label: {
                    labeledRow(icon: "trash.fill", title: "Recycle Bin")
                }
                .listRowBackground(Color.kataSapphire.opacity(0.04))
            } header: {
                sectionHeader("Storage")
            }

            // Pending uploads — only visible when there's something queued
            if pendingCount > 0 {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.cyan.opacity(0.85))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(pendingCount) file\(pendingCount == 1 ? "" : "s") queued")
                                .font(.kataBody(15))
                                .foregroundStyle(.primary)
                            Text(ByteCountFormatter.string(fromByteCount: pendingBytes, countStyle: .file) + " total")
                                .font(.kataCaption(12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isDraining {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                        }
                    }
                    .listRowBackground(Color.cyan.opacity(0.06))

                    Button {
                        isDraining = true
                        Task {
                            await services.syncEngine.syncPending()
                            isDraining = false
                            loadPendingStats()
                        }
                    } label: {
                        Label("Upload Now", systemImage: "arrow.up.circle")
                            .font(.kataBody(15))
                            .foregroundStyle(Color.cyan)
                    }
                    .disabled(isDraining)
                    .listRowBackground(Color.cyan.opacity(0.04))

                    // "Force retry stuck" resets backoff timers + clears any
                    // orphan in-flight markers (background URLSession tasks
                    // that died without firing the delegate). Less destructive
                    // than Clear Stuck Queue — the file rows + chunks stay,
                    // we just nudge the drain to retry every queued chunk
                    // immediately.
                    Button {
                        isDraining = true
                        Task {
                            forceRetryStuckChunks()
                            await services.syncEngine.syncPending()
                            isDraining = false
                            loadPendingStats()
                        }
                    } label: {
                        Label("Force retry stuck", systemImage: "arrow.clockwise.circle")
                            .font(.kataBody(15))
                            .foregroundStyle(Color.orange)
                    }
                    .disabled(isDraining)
                    .listRowBackground(Color.orange.opacity(0.04))
                    .accessibilityHint("Resets backoff timers and orphan in-flight markers so the drain retries every stuck chunk immediately. Doesn't delete anything.")

                    Button(role: .destructive) {
                        confirmClearQueue = true
                    } label: {
                        Label("Clear stuck queue", systemImage: "xmark.bin")
                            .font(.kataBody(15))
                            .foregroundStyle(.red)
                    }
                    .listRowBackground(Color.red.opacity(0.04))
                    .accessibilityHint("Removes pending upload rows that are stuck. Files will need to be re-imported.")
                } header: {
                    sectionHeader("Pending Uploads")
                }
            }

            Section {
                settingsRow(icon: "info.circle.fill", title: "Version", value: "1.0.0")
                settingsLinkRow(
                    icon: "envelope.fill",
                    title: "Send Feedback",
                    url: "mailto:feedback@katafract.com?subject=Vaultyx%20feedback"
                )
                settingsLinkRow(
                    icon: "questionmark.circle.fill",
                    title: "Support",
                    url: "https://katafract.com/support"
                )
                settingsLinkRow(
                    icon: "hand.raised.fill",
                    title: "Privacy Policy",
                    url: "https://katafract.com/privacy/vaultyx"
                )
            } header: {
                sectionHeader("About")
            }

            Section {
                NavigationLink {
                    DebugLogView()
                } label: {
                    labeledRow(icon: "doc.text", title: "Debug Log")
                }
                .listRowBackground(Color.kataSapphire.opacity(0.04))

                NavigationLink {
                    AppGroupDiagnosticsView()
                } label: {
                    labeledRow(icon: "checklist", title: "App Group Diagnostics")
                }
                .listRowBackground(Color.kataSapphire.opacity(0.04))
            } header: {
                sectionHeader("Diagnostics")
            }
        }
        .scrollContentBackground(.hidden)
        .background(
            colorScheme == .dark
                ? AnyView(backgroundTint)
                : AnyView(Color(.systemGroupedBackground))
        )
        .navigationTitle("Settings")
        .task {
            dlog("settings view opened", category: "ui")
            usedBytes = StorageUsageCalculator.compute(from: modelContext)
            Task { await loadServerQuota() }
            loadPendingStats()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultyxFileSynced)) { _ in
            loadPendingStats()
            usedBytes = StorageUsageCalculator.compute(from: modelContext)
        }
        .confirmationDialog(
            "Clear stuck queue?",
            isPresented: $confirmClearQueue,
            titleVisibility: .visible
        ) {
            Button("Clear queue", role: .destructive) {
                clearStuckQueue()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes all pending upload rows and their cached chunks. Files will need to be re-imported. Already-uploaded files are not affected.")
        }
        .sheet(isPresented: $showPhrase) {
            RecoveryPhraseView(
                phrase: RecoveryPhrase.phrase(for: services.masterKey),
                mode: .settings)
        }
        .sheet(isPresented: $showRestore) {
            RestoreFromPhraseView()
        }
        .sheet(isPresented: $showPaywall) {
            CapacityPickerView()
        }
    }

    // MARK: - Row builders

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.kataCaption(11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Color.kataSapphire.opacity(colorScheme == .dark ? 0.85 : 1.0))
            .padding(.top, 4)
    }

    private func settingsRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.kataSapphire)
                .frame(width: 28)
            Text(title)
                .font(.kataBody(15))
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(.kataBody(15))
                .foregroundStyle(.secondary)
        }
        .listRowBackground(Color.kataSapphire.opacity(0.04))
    }

    private func settingsButtonRow(
        icon: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            labeledRow(icon: icon, title: title)
        }
        .listRowBackground(Color.kataSapphire.opacity(0.04))
    }

    private func settingsLinkRow(icon: String, title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            labeledRow(icon: icon, title: title, trailingSymbol: "arrow.up.right")
        }
        .listRowBackground(Color.kataSapphire.opacity(0.04))
    }

    private func labeledRow(
        icon: String,
        title: String,
        trailingSymbol: String? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.kataSapphire)
                .frame(width: 28)
            Text(title)
                .font(.kataBody(15))
                .foregroundStyle(.primary)
            Spacer()
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var heroRecoveryRow: some View {
        Button {
            KataHaptic.revealed.fire()
            showPhrase = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.kataGold)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Recovery Phrase")
                        .font(.kataBody(16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("24-word master key. Write it down once.")
                        .font(.kataCaption(11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.kataGold.opacity(0.8))
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(Color.kataGold.opacity(0.06))
    }

    private var backgroundTint: some View {
        ZStack {
            Color.black
            Color.kataSapphire.opacity(0.05)
        }
        .ignoresSafeArea()
    }

    private func storageDisplayLabel() -> String {
        guard let m = vaultMeta else { return "1 TB" }
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useGB, .useTB]
        bcf.countStyle = .binary
        return "\(bcf.string(fromByteCount: m.usage_bytes)) / \(bcf.string(fromByteCount: m.quota_bytes))"
    }

    private func loadServerQuota() async {
        // Inject seed data if in ScreenshotMode
        if ScreenshotMode.seedData != nil {
            vaultMeta = VaultMetaResponse(
                user_id: "seed-user-id",
                usage_bytes: 342 * 1024 * 1024 * 1024,  // 342 GB
                quota_bytes: 1024 * 1024 * 1024 * 1024,  // 1 TB
                quota_exceeded: false
            )
            return
        }
        do { vaultMeta = try await services.apiClient.vaultMeta() }
        catch { print("vaultMeta fetch failed: \(error)") }
    }

    /// Reset retry-bookkeeping on every pending ChunkUploadQueue row so the
    /// next drain treats them as immediately eligible. Also resets
    /// `nextManifestRetryAt` on LocalFile rows in `manifest_pending` state.
    /// Doesn't delete anything; use Clear Stuck Queue for that.
    private func forceRetryStuckChunks() {
        let queueRows = (try? modelContext.fetch(FetchDescriptor<ChunkUploadQueue>(
            predicate: #Predicate { $0.doneAt == nil }
        ))) ?? []
        let now = Date()
        for row in queueRows {
            row.inFlightTaskIdentifier = nil
            row.lastDispatchedAt = nil
            row.nextRetryAt = now
        }
        let pendingFiles = (try? modelContext.fetch(FetchDescriptor<LocalFile>(
            predicate: #Predicate { $0.syncState == "manifest_pending" }
        ))) ?? []
        for f in pendingFiles { f.nextManifestRetryAt = now }
        try? modelContext.save()
        dlog("force retry: reset \(queueRows.count) chunk(s) + \(pendingFiles.count) manifest-pending file(s)", category: "ui", level: .info)
    }

    /// Drop every ChunkUploadQueue row + every LocalFile in pending_upload /
    /// partial / manifest_pending state, plus their on-disk chunks. Used as
    /// the escape hatch when queued rows are unrecoverable (chunk cache
    /// missing AND plaintext source gone). Already-synced files are
    /// untouched.
    private func clearStuckQueue() {
        let queueRows = (try? modelContext.fetch(FetchDescriptor<ChunkUploadQueue>())) ?? []
        var orphanHashes = Set<String>()
        for row in queueRows {
            orphanHashes.insert(row.chunkHash)
            modelContext.delete(row)
        }
        let stuckFiles = (try? modelContext.fetch(FetchDescriptor<LocalFile>(
            predicate: #Predicate {
                $0.syncState == "pending_upload"
                    || $0.syncState == "partial"
                    || $0.syncState == "manifest_pending"
                    || $0.syncState == "manifest_failed"
                    || $0.syncState == "uploading"
            }
        ))) ?? []
        for f in stuckFiles {
            // Drop the manifest + sidecar cache slots too.
            ChunkCache.delete(hash: "__manifest__\(f.fileId)")
            ChunkCache.delete(hash: "__sidecar__\(f.fileId)")
            modelContext.delete(f)
        }
        try? modelContext.save()
        for hash in orphanHashes { ChunkCache.delete(hash: hash) }
        loadPendingStats()
        usedBytes = StorageUsageCalculator.compute(from: modelContext)
    }

    /// Count + sum pending-upload files from SwiftData.
    private func loadPendingStats() {
        let files = (try? modelContext.fetch(FetchDescriptor<LocalFile>(
            predicate: #Predicate { $0.syncState == "pending_upload" || $0.syncState == "partial" }
        ))) ?? []
        pendingCount = files.count
        pendingBytes = files.reduce(0) { $0 + $1.sizeBytes }
    }
}

// MARK: - Files empty state — "The Sealed Vault"

struct EmptyFolderView: View {
    var onUpload: () -> Void
    /// Called when the non-subscriber "Start with Sovereign" CTA is tapped.
    /// Pass nil when the caller knows the user is already subscribed.
    var onUpgrade: (() -> Void)? = nil

    @State private var shieldScale: CGFloat = 0.94
    @State private var haloOpacity: Double = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                RadialGradient(
                    colors: [Color.kataSapphire.opacity(0.25), Color.kataSapphire.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: 140
                )
                .frame(width: 280, height: 280)
                .opacity(haloOpacity)

                ZStack {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 120, weight: .regular))
                        .foregroundStyle(LinearGradient(
                            colors: [.kataSapphire, .kataSapphire.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))

                    Image(systemName: "lock.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Color.kataGold)
                        .offset(y: 2)
                        .symbolEffect(
                            .pulse,
                            options: .repeating,
                            value: haloOpacity
                        )
                }
                .scaleEffect(shieldScale)
            }

            VStack(spacing: 10) {
                Text("Your vault is empty")
                    .font(.kataHeadline(26, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Add your first file — it'll be encrypted on this device before it ever leaves.")
                    .font(.kataBody(15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // MARK: Sovereign CTA — shown to non-subscribers in empty state (path C for Apple review)
            if let onUpgrade {
                Button {
                    KataHaptic.revealed.fire()
                    onUpgrade()
                } label: {
                    Text("Start with Sovereign — 7-day free trial")
                        .font(.kataHeadline(16, weight: .semibold))
                        .foregroundStyle(Color.kataIce)
                        .frame(maxWidth: 300)
                        .frame(height: 52)
                        .background(Color.kataSapphire)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
            } else {
                Button(action: onUpload) {
                    Label("Upload Files", systemImage: "arrow.up.doc.fill")
                        .font(.kataHeadline(16, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(maxWidth: 260)
                        .frame(height: 52)
                        .background(Color.kataPremiumGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(duration: 0.6, bounce: 0.2)) {
                shieldScale = 1.0
            }
            withAnimation(.easeIn(duration: 0.8)) {
                haloOpacity = 1.0
            }
        }
    }
}

struct DocumentPickerView: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uvc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

struct NewFolderAlert: View {
    @State private var name = ""
    var onCreate: (String) -> Void

    var body: some View {
        TextField("Folder name", text: $name)
        Button("Create") {
            if !name.isEmpty {
                onCreate(name)
            }
        }
        Button("Cancel", role: .cancel) {}
    }
}

#Preview {
    MainTabView()
}
