import SwiftUI

/// Read-only view of DocArmor documents accessible from Vault.
struct DocArmorFolderView: View {
    @StateObject private var viewModel = DocArmorFolderViewModel()

    var body: some View {
        List {
            if viewModel.documents.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "doc.badge.ellipsis")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.kataGold.opacity(0.6))
                    
                    VStack(spacing: 8) {
                        Text("No DocArmor Documents")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Open DocArmor to add documents")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)

            } else {
                ForEach(viewModel.documents) { doc in
                    HStack {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(doc.name).font(.body)
                            Text(doc.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let url = DocArmorBridge.openURL(for: doc.id) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
        }
        .navigationTitle("DocArmor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIApplication.shared.open(URL(string: "docarmor://")!)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
            }
        }
        .task { await viewModel.load() }
    }
}

struct DocArmorDocument: Identifiable {
    let id: String
    let name: String
    let subtitle: String
}

@MainActor
class DocArmorFolderViewModel: ObservableObject {
    @Published var documents: [DocArmorDocument] = []

    func load() async {
        do {
            let response = try await VaultAPIClient.shared.fetchDocArmorFolder()
            documents = response.files.map { file in
                let name = URL(fileURLWithPath: file.key).lastPathComponent
                let sizeKB = Double(file.size) / 1024.0
                let subtitle = String(format: "%.1f KB", sizeKB)
                return DocArmorDocument(id: file.key, name: name, subtitle: subtitle)
            }
        } catch {
            documents = []
        }
    }
}
