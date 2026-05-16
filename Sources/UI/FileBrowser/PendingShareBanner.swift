import SwiftUI
import KatafractStyle

/// Banner shown at the top of FileBrowserView when files are waiting in the
/// share extension inbox to be drained. Allows the user to import them immediately
/// without waiting for the next .active scene phase transition.
struct PendingShareBanner: View {
    let count: Int
    let onDrain: () -> Void

    var body: some View {
        Button(action: {
            UISelectionFeedbackGenerator().selectionChanged()
            onDrain()
        }) {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 14, weight: .semibold))

                Text("\(count) file\(count == 1 ? "" : "s") waiting from share sheet")
                    .font(.kataMono(13))

                Spacer()

                Text("Tap to import")
                    .font(.kataMono(12))
                    .foregroundStyle(Color.kataGold)
            }
        }
        .foregroundStyle(Color.kataChampagne)
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
        PendingShareBanner(count: 3) {}
        Spacer()
    }
    .background(Color(.systemGroupedBackground))
}
