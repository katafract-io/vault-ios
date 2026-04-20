import SwiftUI

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
    }
}

// MARK: - Placeholder Views

struct RecentsView: View {
    var body: some View {
        Text("Recent Files")
            .navigationTitle("Recent")
    }
}

struct SettingsView: View {
    @ObservedObject private var lock = BiometricLock.shared
    @EnvironmentObject private var services: VaultServices
    @Environment(\.modelContext) private var modelContext
    @State private var usedBytes: Int64 = -1
    @State private var showPhrase = false
    @State private var showRestore = false

    private let sovereignQuota: Int64 = 1_099_511_627_776  // 1 TiB

    var body: some View {
        List {
            StorageQuotaView(usedBytes: usedBytes, totalBytes: sovereignQuota)
                .listRowInsets(EdgeInsets())
            Section("Account") {
                LabeledContent("Plan", value: "Sovereign")
                LabeledContent("Storage", value: "1 TB")
            }
            Section("Security") {
                Button {
                    showPhrase = true
                } label: {
                    HStack {
                        Text("Show Recovery Phrase")
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: "key.horizontal.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    showRestore = true
                } label: {
                    Text("Restore from Recovery Phrase")
                        .foregroundStyle(Color.primary)
                }
                Toggle("Biometric Lock", isOn: $lock.isEnabled)
            }
            Section("Storage") {
                NavigationLink("Recycle Bin") {
                    RecycleBinView()
                }
            }
            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                Link(destination: URL(string: "mailto:feedback@katafract.com?subject=Vaultyx%20feedback")!) {
                    HStack {
                        Text("Send Feedback")
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                Link(destination: URL(string: "https://katafract.com/support")!) {
                    HStack {
                        Text("Support")
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                Link(destination: URL(string: "https://katafract.com/privacy/vaultyx")!) {
                    HStack {
                        Text("Privacy Policy")
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
}

struct EmptyFolderView: View {
    var onUpload: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Empty Folder", systemImage: "folder")
        } description: {
            Text("Upload files to get started")
        } actions: {
            Button("Upload Files", action: onUpload)
                .buttonStyle(.borderedProminent)
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
