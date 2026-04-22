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
        // TODO: list objects from docarmor-vaults/{user_id}/ S3 prefix via Vault API
        // Placeholder
        documents = []
    }
}
