import SwiftUI
import VisionKit
import PDFKit

struct DocumentScannerView: UIViewControllerRepresentable {
    var onScan: ([URL]) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, dismiss: dismiss)
    }

    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([URL]) -> Void
        let dismiss: DismissAction

        init(onScan: @escaping ([URL]) -> Void, dismiss: DismissAction) {
            self.onScan = onScan
            self.dismiss = dismiss
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            let pdfURL = renderScannedDocumentsToPDF(scan)
            if let pdfURL {
                onScan([pdfURL])
            }
            dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            dismiss()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            dismiss()
        }

        private func renderScannedDocumentsToPDF(_ scan: VNDocumentCameraScan) -> URL? {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
            let timestamp = formatter.string(from: Date())
            let filename = "Scan-\(timestamp).pdf"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

            let pdfDocument = PDFDocument()

            for pageIndex in 0..<scan.pageCount {
                let documentImage = scan.imageOfPage(at: pageIndex)
                guard let pdfPage = PDFPage(image: documentImage) else { continue }
                pdfDocument.insert(pdfPage, at: pageIndex)
            }

            return pdfDocument.write(to: tempURL) ? tempURL : nil
        }
    }
}
