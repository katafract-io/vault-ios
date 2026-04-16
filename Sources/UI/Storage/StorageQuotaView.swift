import SwiftUI

struct StorageQuotaView: View {
    let usedBytes: Int64
    let totalBytes: Int64

    var progress: Double {
        Double(usedBytes) / Double(totalBytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Vault Storage")
                    .font(.headline)
                Spacer()
                Text("\(formatted(usedBytes)) of \(formatted(totalBytes))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
                .tint(progress > 0.9 ? .red : progress > 0.75 ? .orange : .blue)
            Text("\(formatted(totalBytes - usedBytes)) available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    StorageQuotaView(usedBytes: 500_000_000_000, totalBytes: 1_099_511_627_776)
        .padding()
}
