import SwiftUI
import KatafractStyle

/// Aggregate upload-progress banner shown at the top of FileBrowserView
/// while a batch upload is in progress. Mirrors the visual language of
/// BackupProgressBanner in PhotosView: kataMidnight card, gold hairline
/// progress bar, champagne mono type, inline Cancel button.
struct FileUploadProgressBanner: View {
    let fileIndex: Int          // 1-based, current file being uploaded
    let totalFiles: Int
    let bytesUploaded: Int64
    let totalBytes: Int64
    let onCancel: () -> Void

    private var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytesUploaded) / Double(totalBytes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                // Spinning progress indicator
                KataProgressRing(size: 18)

                // Local import/sealing count. The network backup continues
                // through the sync queue after this fast path returns.
                Text("Sealing \(fileIndex) of \(totalFiles)")
                    .font(.kataMono(12))
                    .foregroundStyle(Color.kataChampagne)

                Spacer()

                // Cancel pill
                Button(action: {
                    KataHaptic.destructive.fire()
                    onCancel()
                }) {
                    Text("Cancel")
                        .font(.kataMono(12))
                        .foregroundStyle(Color.kataIce)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.kataMidnight.opacity(0.4))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.kataIce.opacity(0.25), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            Text("Encrypting locally. Encrypted backup continues in Sync Queue.")
                .font(.kataMono(10))
                .foregroundStyle(Color.kataChampagne.opacity(0.65))
                .lineLimit(1)

            // Gold hairline progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.kataGold.opacity(0.25))
                        .frame(height: 2)
                    // Fill
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.kataChampagne)
                        .frame(width: geo.size.width * fraction, height: 2)
                        .animation(.linear(duration: 0.3), value: fraction)
                }
            }
            .frame(height: 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.kataMidnight)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.kataGold.opacity(0.2), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

#Preview {
    VStack {
        FileUploadProgressBanner(
            fileIndex: 3,
            totalFiles: 7,
            bytesUploaded: 1_200_000,
            totalBytes: 3_000_000,
            onCancel: {}
        )
        Spacer()
    }
    .background(Color(.systemGroupedBackground))
}
