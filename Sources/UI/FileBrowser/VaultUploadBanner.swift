import SwiftUI
import KatafractStyle

/// Queue-level upload progress banner pinned to top of Files tab.
/// Shows count of queued uploads + overall speed or waiting state.
struct VaultUploadBanner: View {
    @State private var activeUploads: [FileUploadQueue] = []
    @State private var refreshTimer: Timer?

    private var uploadCount: Int {
        activeUploads.count
    }

    private var totalProgress: Double {
        guard activeUploads.count > 0 else { return 0 }
        let totalChunks = activeUploads.reduce(0) { $0 + $1.totalChunks }
        let doneChunks = activeUploads.reduce(0) { $0 + $1.chunksDone }
        return totalChunks > 0 ? Double(doneChunks) / Double(totalChunks) : 0
    }

    private var statusText: String {
        switch uploadCount {
        case 0:
            return "No uploads"
        case 1:
            return "1 file uploading"
        default:
            return "\(uploadCount) files uploading"
        }
    }

    var body: some View {
        if uploadCount > 0 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    KataProgressRing(size: 18)

                    Text(statusText)
                        .font(.kataMono(12))
                        .foregroundStyle(Color.kataChampagne)

                    Spacer()
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.kataGold.opacity(0.25))
                            .frame(height: 2)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.kataChampagne)
                            .frame(width: geo.size.width * totalProgress, height: 2)
                            .animation(.linear(duration: 0.3), value: totalProgress)
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
            .onAppear { startRefresh() }
            .onDisappear { stopRefresh() }
        }
    }

    private func startRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            activeUploads = VaultUploadQueue.shared.activeUploads()
        }
        activeUploads = VaultUploadQueue.shared.activeUploads()
    }

    private func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

#Preview {
    VStack {
        VaultUploadBanner()
        Spacer()
    }
    .background(Color(.systemGroupedBackground))
}
