import SwiftUI
import KatafractStyle

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

// MARK: - Placeholder Views

struct RecentsView: View {
    var body: some View {
        Text("Recent Files")
            .navigationTitle("Recent")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject private var lock = BiometricLock.shared
    @EnvironmentObject private var services: VaultServices
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var usedBytes: Int64 = -1
    @State private var showPhrase = false
    @State private var showRestore = false

    private let sovereignQuota: Int64 = 1_099_511_627_776  // 1 TiB

    var body: some View {
        List {
            StorageQuotaView(usedBytes: usedBytes, totalBytes: sovereignQuota)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

            Section {
                settingsRow(icon: "person.crop.circle.fill", title: "Plan", value: "Sovereign")
                settingsRow(icon: "externaldrive.fill", title: "Storage", value: "1 TB")
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
        }
        .scrollContentBackground(.hidden)
        .background(
            colorScheme == .dark
                ? AnyView(backgroundTint)
                : AnyView(Color(.systemGroupedBackground))
        )
        .navigationTitle("Settings")
        .task {
            usedBytes = StorageUsageCalculator.compute(from: modelContext)
        }
        .sheet(isPresented: $showPhrase) {
            RecoveryPhraseView(
                phrase: RecoveryPhrase.phrase(for: services.masterKey),
                mode: .settings)
        }
        .sheet(isPresented: $showRestore) {
            RestoreFromPhraseView()
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
}

// MARK: - Files empty state — "The Sealed Vault"

struct EmptyFolderView: View {
    var onUpload: () -> Void

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

            Button(action: onUpload) {
                Label("Upload Files", systemImage: "arrow.up.doc.fill")
                    .font(.kataHeadline(16, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: 260)
                    .frame(height: 52)
                    .background(Color.kataPremiumGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.top, 4)

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
