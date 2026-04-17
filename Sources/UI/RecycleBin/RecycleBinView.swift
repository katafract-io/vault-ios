import SwiftUI
import SwiftData

struct RecycleBinView: View {
    @EnvironmentObject private var services: VaultServices
    @StateObject private var viewModel = RecycleBinViewModel()

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.files.isEmpty && viewModel.folders.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.files.isEmpty && viewModel.folders.isEmpty {
                ContentUnavailableView(
                    "Recycle Bin Empty",
                    systemImage: "trash",
                    description: Text("Deleted items appear here for 30 days before being permanently removed."))
            } else {
                List {
                    if !viewModel.folders.isEmpty {
                        Section("Folders") {
                            ForEach(viewModel.folders) { folder in
                                TrashedFolderRow(folder: folder)
                                    .swipeActions(edge: .leading) {
                                        Button {
                                            Task { await viewModel.restore(folder: folder) }
                                        } label: {
                                            Label("Restore", systemImage: "arrow.uturn.backward")
                                        }
                                        .tint(.green)
                                    }
                            }
                        }
                    }
                    if !viewModel.files.isEmpty {
                        Section("Files") {
                            ForEach(viewModel.files) { file in
                                TrashedFileRow(file: file)
                                    .swipeActions(edge: .leading) {
                                        Button {
                                            Task { await viewModel.restore(file: file) }
                                        } label: {
                                            Label("Restore", systemImage: "arrow.uturn.backward")
                                        }
                                        .tint(.green)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            Task { await viewModel.purge(file: file) }
                                        } label: {
                                            Label("Delete Now", systemImage: "trash.fill")
                                        }
                                    }
                            }
                        }
                    }
                    Section {
                        Text("Items are permanently deleted after 30 days. Storage is released immediately on permanent delete.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Recycle Bin")
        .task {
            viewModel.configure(services: services)
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load()
        }
        .alert("Couldn't restore",
               isPresented: Binding(
                   get: { viewModel.error != nil },
                   set: { if !$0 { viewModel.error = nil } }),
               presenting: viewModel.error) { _ in
            Button("OK") { viewModel.error = nil }
        } message: { err in
            Text(err)
        }
    }
}

private struct TrashedFileRow: View {
    let file: RecycleBinViewModel.FileItem
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.body).lineLimit(1)
                Text("\(file.formattedSize) · deleted \(file.deletedAt, style: .relative) ago")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(file.expiresLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(file.expiringSoon ? .orange : .secondary)
        }
    }
}

private struct TrashedFolderRow: View {
    let folder: RecycleBinViewModel.FolderItem
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.body).lineLimit(1)
                Text("deleted \(folder.deletedAt, style: .relative) ago")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(folder.expiresLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(folder.expiringSoon ? .orange : .secondary)
        }
    }
}

@MainActor
final class RecycleBinViewModel: ObservableObject {

    struct FileItem: Identifiable {
        let id: String
        let name: String
        let sizeBytes: Int64
        let deletedAt: Date
        let expiresAt: Date

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
        var expiresLabel: String {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
            return "\(max(days, 0))d left"
        }
        var expiringSoon: Bool {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
            return days <= 3
        }
    }

    struct FolderItem: Identifiable {
        let id: String
        let name: String
        let deletedAt: Date
        let expiresAt: Date
        /// Cascade-batch timestamp — same for every row deleted together.
        let batchTimestamp: Int

        var expiresLabel: String {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
            return "\(max(days, 0))d left"
        }
        var expiringSoon: Bool {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
            return days <= 3
        }
    }

    @Published var files: [FileItem] = []
    @Published var folders: [FolderItem] = []
    @Published var isLoading = false
    @Published var error: String?

    private weak var services: VaultServices?

    func configure(services: VaultServices) {
        self.services = services
    }

    func load() async {
        guard let services else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let filesResp = services.apiClient.listTrashFiles()
            async let foldersResp = services.apiClient.listTrashFolders()
            let (fr, frd) = try await (filesResp, foldersResp)

            // Decrypt names in parallel under the parent folder key (for
            // folders) and... for files we don't know the parent in the
            // trash response. The trashed file's `filename_enc` was encrypted
            // under its original folder key. Best-effort: try the root key,
            // fall back to placeholder.
            self.files = []
            for rec in fr.files {
                let decoded = (try? await services.keyManager
                    .getOrCreateFolderKey(folderId: "root")).map {
                    (try? decryptName(rec.filename_enc, key: $0)) ?? "File"
                } ?? "File"
                self.files.append(FileItem(
                    id: rec.file_id,
                    name: decoded,
                    sizeBytes: rec.size_bytes,
                    deletedAt: Date(timeIntervalSince1970: TimeInterval(rec.deleted_at)),
                    expiresAt: Date(timeIntervalSince1970: TimeInterval(rec.expires_at))))
            }

            self.folders = []
            for rec in frd.folders {
                let parentId = rec.parent_folder_id ?? "root"
                let decoded = (try? await services.keyManager
                    .getOrCreateFolderKey(folderId: parentId)).map {
                    (try? decryptName(rec.name_enc, key: $0)) ?? "Folder"
                } ?? "Folder"
                self.folders.append(FolderItem(
                    id: rec.folder_id,
                    name: decoded,
                    deletedAt: Date(timeIntervalSince1970: TimeInterval(rec.deleted_at)),
                    expiresAt: Date(timeIntervalSince1970: TimeInterval(rec.expires_at)),
                    batchTimestamp: rec.deleted_at))
            }
        } catch {
            self.error = "Couldn't load trash: \(error.localizedDescription)"
        }
    }

    func restore(file: FileItem) async {
        guard let services else { return }
        do {
            try await services.apiClient.restoreFile(fileId: file.id)
            files.removeAll { $0.id == file.id }
        } catch {
            self.error = "Restore failed: \(error.localizedDescription)"
        }
    }

    func restore(folder: FolderItem) async {
        guard let services else { return }
        do {
            let resp = try await services.apiClient.restoreFolder(folderId: folder.id)
            // Server restored the whole cascade batch (all rows with matching
            // deleted_at). Reflect that in the local trash UI by stripping
            // everything that was deleted at the same batch timestamp.
            folders.removeAll { $0.batchTimestamp == folder.batchTimestamp }
            files.removeAll {
                Int($0.deletedAt.timeIntervalSince1970) == folder.batchTimestamp
            }
            _ = resp
        } catch {
            self.error = "Restore failed: \(error.localizedDescription)"
        }
    }

    func purge(file: FileItem) async {
        guard let services else { return }
        do {
            try await services.apiClient.purgeFile(fileId: file.id)
            files.removeAll { $0.id == file.id }
        } catch {
            self.error = "Permanent delete failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func decryptName(_ encB64: String, key: CryptoKitSymmetricKey) throws -> String {
        guard !encB64.isEmpty, let data = Data(base64Encoded: encB64) else { return "" }
        let decrypted = try VaultCrypto.decrypt(data, key: key)
        return String(data: decrypted, encoding: .utf8) ?? ""
    }
}

import CryptoKit
private typealias CryptoKitSymmetricKey = SymmetricKey

#Preview {
    NavigationStack {
        RecycleBinView()
    }
}
