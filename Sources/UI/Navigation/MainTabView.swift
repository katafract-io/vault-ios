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
                            onRename: { _ in },
                            onDelete: {},
                            onPin: { viewModel.togglePin(item) }
                        )
                        .onTapGesture { selectedFile = item }
                    }
                }
            }
        }
        .navigationTitle("Recent")
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
                            selectedFile = nil
                        }
                    }
            }
        }
        .task {
            viewModel.configure(services: services)
            await viewModel.load()
        }
        .onAppear {
            Task {
                viewModel.configure(services: services)
                await viewModel.load()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaultRecentsDidChange)) { _ in
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

    func load() async {
        isLoading = true
        defer { isLoading = false }

        // Inject seed data if in ScreenshotMode
        if ScreenshotMode.seedData != nil {
            injectSeedRecentFiles()
            return
        }

        guard let services else {
            items = []
            return
        }

        let context = ModelContext(services.modelContainer)
        let rows = (try? context.fetch(FetchDescriptor<LocalFile>())) ?? []
        items = rows
            .sorted {
                ($0.lastOpenedAt ?? $0.modifiedAt) > ($1.lastOpenedAt ?? $1.modifiedAt)
            }
            .prefix(20)
            .map { row in
                let syncDisplay: VaultFileItem.SyncStateDisplay
                switch row.syncState {
                case "pending_upload": syncDisplay = .pendingUpload
                case "partial":        syncDisplay = .partial
                case "uploading":      syncDisplay = .uploading(0)
                case "downloading":    syncDisplay = .downloading(0)
                case "conflict":       syncDisplay = .conflict
                default:               syncDisplay = .synced
                }
                return VaultFileItem(
                    id: row.fileId,
                    name: row.filename,
                    isFolder: false,
                    sizeBytes: row.sizeBytes,
                    modifiedAt: row.lastOpenedAt ?? row.modifiedAt,
                    parentFolderId: row.parentFolderId,
                    syncState: syncDisplay,
                    isPinned: row.isPinned
                )
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

    func materializeLocalURL(for item: VaultFileItem, markOpened: Bool = true) async -> URL? {
        guard let services else {
            error = "VaultServices not configured"
            return nil
        }
        let context = ModelContext(services.modelContainer)
        let row = (try? context.fetch(FetchDescriptor<LocalFile>()))?
            .first { $0.fileId == item.id }
        if let cachedPath = row?.localPath, LocalCache.exists(at: cachedPath) {
            if markOpened {
                row?.lastOpenedAt = Date()
            }
            try? context.save()
            NotificationCenter.default.post(name: .vaultRecentsDidChange, object: nil)
            await load()
            return URL(fileURLWithPath: cachedPath)
        }

        do {
            let folderKey = try await services.keyManager.getOrCreateFolderKey(
                folderId: item.parentFolderId ?? "root")
            let plaintext = try await services.syncEngine.downloadFile(
                fileId: item.id, folderKey: folderKey)
            let cached = try LocalCache.adoptData(
                fileId: item.id, originalName: item.name, data: plaintext)
            if let row {
                row.localPath = cached.path
                if markOpened {
                    row.lastOpenedAt = Date()
                }
                try? context.save()
                NotificationCenter.default.post(name: .vaultRecentsDidChange, object: nil)
            }
            await load()
            return cached
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
                if row.isPinned {
                    row.isPinned = false
                } else if let localPath = row.localPath, LocalCache.exists(at: localPath) {
                    row.isPinned = true
                } else {
                    Task {
                        guard await materializeLocalURL(for: item, markOpened: false) != nil else { return }
                        let context = ModelContext(services.modelContainer)
                        if let rows = try? context.fetch(FetchDescriptor<LocalFile>()) {
                            for row in rows where row.fileId == item.id {
                                row.isPinned = true
                            }
                            try? context.save()
                        }
                        await load()
                    }
                    return
                }
            }
            try? context.save()
        }
        Task { await load() }
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
    @State private var offlineCount: Int = 0
    @State private var offlineBytes: Int64 = 0
    @State private var pinnedCount: Int = 0

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

            Section {
                settingsRow(
                    icon: "externaldrive.fill",
                    title: "Available Offline",
                    value: "\(offlineCount) · \(ByteCountFormatter.string(fromByteCount: offlineBytes, countStyle: .file))"
                )
                settingsRow(
                    icon: "pin.fill",
                    title: "Kept Offline",
                    value: "\(pinnedCount)"
                )

                Button {
                    clearUnpinnedDownloads()
                } label: {
                    Label("Clear Unpinned Downloads", systemImage: "externaldrive.badge.xmark")
                        .font(.kataBody(15))
                        .foregroundStyle(Color.kataSapphire)
                }
                .disabled(offlineCount == pinnedCount)
                .listRowBackground(Color.kataSapphire.opacity(0.04))
            } header: {
                sectionHeader("Offline Files")
            } footer: {
                Text("Pinned files stay on this device. Opened files may be kept for fast preview until cleared.")
                    .font(.kataCaption(11))
            }

            // Sync queue — only visible when there's something queued.
            if pendingCount > 0 {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.cyan.opacity(0.85))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(pendingCount) encrypted backup\(pendingCount == 1 ? "" : "s") queued")
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
                        Label("Back Up Now", systemImage: "arrow.up.circle")
                            .font(.kataBody(15))
                            .foregroundStyle(Color.cyan)
                    }
                    .disabled(isDraining)
                    .listRowBackground(Color.cyan.opacity(0.04))
                } header: {
                    sectionHeader("Sync Queue")
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
            loadOfflineStats()
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

    /// Count + sum pending-upload files from SwiftData.
    private func loadPendingStats() {
        let files = (try? modelContext.fetch(FetchDescriptor<LocalFile>(
            predicate: #Predicate { $0.syncState == "pending_upload" || $0.syncState == "partial" }
        ))) ?? []
        pendingCount = files.count
        pendingBytes = files.reduce(0) { $0 + $1.sizeBytes }
    }

    private func loadOfflineStats() {
        let files = (try? modelContext.fetch(FetchDescriptor<LocalFile>())) ?? []
        let offline = files.filter { file in
            guard let path = file.localPath else { return false }
            return LocalCache.exists(at: path)
        }
        offlineCount = offline.count
        pinnedCount = offline.filter(\.isPinned).count
        offlineBytes = offline.reduce(Int64(0)) { total, file in
            guard let path = file.localPath else { return total }
            return total + LocalCache.byteCount(at: path)
        }
    }

    private func clearUnpinnedDownloads() {
        let files = (try? modelContext.fetch(FetchDescriptor<LocalFile>())) ?? []
        for file in files where !file.isPinned {
            guard let path = file.localPath, LocalCache.exists(at: path) else { continue }
            LocalCache.remove(at: path)
            file.localPath = nil
        }
        try? modelContext.save()
        loadOfflineStats()
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
