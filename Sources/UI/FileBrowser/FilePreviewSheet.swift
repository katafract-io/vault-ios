import SwiftUI
import QuickLook
import KatafractStyle

/// Sheet that hosts QLPreviewController for a single decrypted, on-disk file.
///
/// Loading + ready + error states live inside a single NavigationStack so the
/// content swap doesn't tear down the navigation chrome (that tear-down was
/// the source of the flicker/loop the user saw on tap → preview). The
/// `.animation(nil, value:)` modifier suppresses the implicit transition on
/// the inner body switch so the appearance change feels instantaneous.
struct FilePreviewSheet: View {
    let displayName: String
    let fileURL: URL?
    let errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(fileURL == nil && errorMessage != nil ? "Dismiss" : (fileURL == nil ? "Cancel" : "Done")) {
                            dismiss()
                        }
                    }
                }
                .animation(nil, value: fileURL)
                .animation(nil, value: errorMessage)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let fileURL {
            QuickLookPreview(url: fileURL)
                .ignoresSafeArea()
        } else if let errorMessage {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.tertiary)
                Text("Couldn't open \(displayName)")
                    .font(.headline)
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        } else {
            VStack(spacing: 16) {
                KataProgressRing(size: 40)
                Text("Preparing \(displayName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Minimal QLPreviewController host. One-file mode only.
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uvc: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}

/// Sheet shown while the local URL is still being materialized (download +
/// decrypt). When `errorMessage` is set, swaps to an error layout instead of
/// dismissing — keeps the failure visible until the user taps Dismiss, which
/// avoids the sheet-dismiss-races-the-alert race we hit on iOS.
struct FilePreviewLoadingSheet: View {
    let displayName: String
    var errorMessage: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let errorMessage {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(.tertiary)
                    Text("Couldn't open \(displayName)")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else {
                    KataProgressRing(size: 40)
                    Text("Preparing \(displayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(errorMessage == nil ? "Cancel" : "Dismiss") { dismiss() }
                }
            }
        }
    }
}
