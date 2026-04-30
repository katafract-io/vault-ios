import SwiftUI
import SwiftData
import KatafractStyle

/// Sum of local `LocalFile.sizeBytes` + `BackedUpAsset.sizeBytes` in SwiftData.
///
/// This reflects what this device knows about — not the true server-side
/// quota consumption. When the server-side /v1/vault/usage endpoint exists,
/// swap this for a network fetch. Until then, it at least won't show
/// the hardcoded 42 GB lie.
@MainActor
final class StorageUsageCalculator {
    static func compute(from context: ModelContext) -> Int64 {
        let files = (try? context.fetch(FetchDescriptor<LocalFile>())) ?? []
        let photos = (try? context.fetch(FetchDescriptor<BackedUpAsset>())) ?? []
        return files.reduce(0) { $0 + $1.sizeBytes } +
               photos.reduce(0) { $0 + $1.sizeBytes }
    }
}

struct StorageQuotaView: View {
    let usedBytes: Int64
    let totalBytes: Int64
    @EnvironmentObject private var subscriptionStore: SubscriptionStore

    /// `nil` for `usedBytes` renders "—" instead of a garbage number while
    /// usage is still being computed (or there's no data yet).
    private var hasUsage: Bool { usedBytes >= 0 }

    private var capacityBytes: Int64 {
        subscriptionStore.activeCapacity?.bytes ?? totalBytes
    }

    var progress: Double {
        guard hasUsage, capacityBytes > 0 else { return 0 }
        return min(Double(usedBytes) / Double(capacityBytes), 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Vault Storage")
                    .font(.headline)
                Spacer()
                Text(hasUsage
                     ? "\(formatted(usedBytes)) of \(formatted(capacityBytes))"
                     : "— of \(formatted(capacityBytes))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            KataProgressRing(progress: progress)
            Text(hasUsage
                 ? "\(formatted(capacityBytes - usedBytes)) available"
                 : "Usage not yet calculated")
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
