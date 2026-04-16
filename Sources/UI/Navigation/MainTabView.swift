import SwiftUI

struct MainTabView: View {
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
    var body: some View {
        List {
            StorageQuotaView(usedBytes: 42_000_000_000, totalBytes: 1_099_511_627_776)
                .listRowInsets(EdgeInsets())
            Section("Account") {
                LabeledContent("Plan", value: "Sovereign")
                LabeledContent("Storage", value: "1 TB")
            }
            Section("Security") {
                NavigationLink("Recovery Key") {
                    Text("Recovery Key")
                        .navigationTitle("Recovery Key")
                }
                Toggle("Biometric Lock", isOn: .constant(true))
            }
            Section("Storage") {
                NavigationLink("Recycle Bin") {
                    RecycleBinView()
                }
            }
            Section("About") {
                LabeledContent("Version", value: "1.0.0")
            }
        }
        .navigationTitle("Settings")
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
