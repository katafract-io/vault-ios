import SwiftUI

struct RecycleBinView: View {
    @StateObject private var viewModel = RecycleBinViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.deletedFiles.isEmpty {
                    ContentUnavailableView(
                        "Recycle Bin Empty",
                        systemImage: "trash",
                        description: Text("Deleted files appear here for 30 days")
                    )
                } else {
                    List {
                        Section {
                            ForEach(viewModel.deletedFiles) { file in
                                HStack {
                                    Image(systemName: "doc.fill")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name).font(.body)
                                        Text("Deleted \(file.deletedAt, style: .relative) ago · \(file.formattedSize)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(file.expiresIn)
                                        .font(.caption2)
                                        .foregroundStyle(file.expiringSoon ? .orange : .secondary)
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        viewModel.restore(file)
                                    } label: {
                                        Label("Restore", systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(.green)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        viewModel.permanentlyDelete(file)
                                    } label: {
                                        Label("Delete Forever", systemImage: "trash.fill")
                                    }
                                }
                            }
                        } footer: {
                            Text("Files are permanently deleted after 30 days.")
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Recycle Bin")
            .toolbar {
                if !viewModel.deletedFiles.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Empty", role: .destructive) {
                            viewModel.showEmptyConfirmation = true
                        }
                    }
                }
            }
            .confirmationDialog(
                "Empty Recycle Bin?",
                isPresented: $viewModel.showEmptyConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All \(viewModel.deletedFiles.count) Files", role: .destructive) {
                    viewModel.emptyBin()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This action cannot be undone.")
            }
            .task { await viewModel.load() }
        }
    }
}

struct DeletedFileItem: Identifiable {
    let id: String
    let name: String
    let sizeBytes: Int64
    let deletedAt: Date
    let expiresAt: Date

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var expiresIn: String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
        return "\(days)d left"
    }

    var expiringSoon: Bool {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
        return days <= 3
    }
}

@MainActor
class RecycleBinViewModel: ObservableObject {
    @Published var deletedFiles: [DeletedFileItem] = []
    @Published var showEmptyConfirmation = false

    func load() async {
        // TODO: GET /v1/vault/trash from API
    }

    func restore(_ file: DeletedFileItem) {
        // TODO: POST /v1/vault/files/{id}/restore
        deletedFiles.removeAll { $0.id == file.id }
    }

    func permanentlyDelete(_ file: DeletedFileItem) {
        // TODO: DELETE /v1/vault/files/{id}?permanent=true
        deletedFiles.removeAll { $0.id == file.id }
    }

    func emptyBin() {
        // TODO: DELETE /v1/vault/trash
        deletedFiles.removeAll()
    }
}

#Preview {
    RecycleBinView()
}
