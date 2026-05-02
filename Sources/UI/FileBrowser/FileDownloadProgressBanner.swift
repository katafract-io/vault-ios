import SwiftUI
import KatafractStyle

/// Download-progress banner shown at the top of FileBrowserView while a file
/// is being fetched and decrypted. Matches the visual language of
/// FileUploadProgressBanner: kataMidnight card, gold hairline progress bar,
/// champagne mono type, inline Cancel button.
struct FileDownloadProgressBanner: View {
    let filename: String
    let progress: Double          // 0.0 – 1.0
    let onCancel: () -> Void

    private var fraction: Double { min(1.0, max(0, progress)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                // Spinning progress indicator
                KataProgressRing(size: 18)

                // Filename (truncated) + percentage
                Text("Unsealing \(filename)")
                    .font(.kataMono(12))
                    .foregroundStyle(Color.kataChampagne)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // Percentage label
                Text("\(Int(fraction * 100))%")
                    .font(.kataMono(12))
                    .foregroundStyle(Color.kataChampagne.opacity(0.7))
                    .monospacedDigit()

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
        FileDownloadProgressBanner(
            filename: "Q4 Financial Report.pdf",
            progress: 0.62,
            onCancel: {}
        )
        Spacer()
    }
    .background(Color(.systemGroupedBackground))
}
