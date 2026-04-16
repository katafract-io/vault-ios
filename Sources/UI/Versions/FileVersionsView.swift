import SwiftUI

struct FileVersionsView: View {
    let fileId: String
    let filename: String
    @StateObject private var viewModel = FileVersionsViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.versions.isEmpty {
                    ContentUnavailableView(
                        "No Version History",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Previous versions will appear here")
                    )
                } else {
                    List {
                        ForEach(Array(viewModel.versions.enumerated()), id: \.element.id) { index, version in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        if index == 0 {
                                            Text("Current")
                                                .font(.caption)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.blue)
                                                .foregroundStyle(.white)
                                                .cornerRadius(4)
                                        }
                                        Text(version.modifiedAt, style: .date)
                                            .font(.subheadline)
                                    }
                                    HStack(spacing: 8) {
                                        Text(version.formattedSize)
                                        Text("·")
                                        Text(version.modifiedAt, style: .time)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if index != 0 {
                                    Button("Restore") {
                                        viewModel.restore(version)
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await viewModel.load(fileId: fileId) }
        }
    }
}

struct FileVersion: Identifiable {
    let id: String
    let version: Int
    let sizeBytes: Int64
    let modifiedAt: Date

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

@MainActor
class FileVersionsViewModel: ObservableObject {
    @Published var versions: [FileVersion] = []

    func load(fileId: String) async {
        // TODO: GET /v1/vault/versions/{fileId}
    }

    func restore(_ version: FileVersion) {
        // TODO: POST /v1/vault/files/{fileId}/restore?version={version.version}
    }
}

#Preview {
    FileVersionsView(fileId: "example", filename: "document.pdf")
}
