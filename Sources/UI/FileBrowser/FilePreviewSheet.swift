import SwiftUI
import QuickLook

/// Sheet that hosts QLPreviewController for a single decrypted, on-disk file.
///
/// The URL must point to a real file that QuickLook can read directly —
/// this is the caller's responsibility (download chunks, decrypt, write to a
/// tmp path, then present this sheet with that URL). QLPreviewController
/// handles PDF, Office docs, images, video, audio, text, and more natively.
struct FilePreviewSheet: View {
    let fileURL: URL
    let displayName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QuickLookPreview(url: fileURL)
                .ignoresSafeArea()
                .navigationTitle(displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
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

/// Sheet shown while the local URL is still being materialized (download + decrypt).
struct FilePreviewLoadingSheet: View {
    let displayName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.4)
                Text("Preparing \(displayName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
