import SwiftUI
import KatafractStyle

struct FileVersionsView: View {
    let fileId: String
    let filename: String
    @StateObject private var viewModel = FileVersionsViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.versions.isEmpty {
                    VStack(spacing: 24) {
                        // Sealed-parchment stack: faded sheets + wax-seal dot
                        ZStack {
                            RoundedRectangle(cornerRadius: 1)
                                .stroke(Color.kataGold.opacity(0.15), lineWidth: 0.5)
                                .frame(width: 120, height: 160)
                                .rotationEffect(.degrees(-6))
                                .offset(x: -8, y: 6)
                            RoundedRectangle(cornerRadius: 1)
                                .stroke(Color.kataGold.opacity(0.22), lineWidth: 0.5)
                                .frame(width: 120, height: 160)
                                .rotationEffect(.degrees(-2))
                                .offset(x: -3, y: 2)
                            RoundedRectangle(cornerRadius: 1)
                                .stroke(Color.kataGold.opacity(0.35), lineWidth: 0.5)
                                .frame(width: 120, height: 160)
                            Circle()
                                .fill(Color.kataGold)
                                .frame(width: 10, height: 10)
                                .offset(y: 60)
                        }
                        .frame(width: 140, height: 180)

                        Text("No prior versions sealed yet.")
                            .font(.kataDisplay(20))
                            .foregroundStyle(Color.kataIce)
                            .multilineTextAlignment(.center)

                        Text("Versions are captured each time you upload a new copy of this file.")
                            .font(.kataBody(14))
                            .foregroundStyle(Color.kataIce.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.kataMidnight.opacity(0.02))
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
