import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        processSharedItems()
    }

    private func processSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            cancel()
            return
        }

        Task {
            var urls: [URL] = []
            for item in extensionItems {
                for provider in (item.attachments ?? []) {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                            urls.append(url)
                        }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                        if let data = try? await provider.loadItem(forTypeIdentifier: UTType.data.identifier) as? Data {
                            let tmpURL = FileManager.default.temporaryDirectory
                                .appendingPathComponent(UUID().uuidString)
                            try? data.write(to: tmpURL)
                            urls.append(tmpURL)
                        }
                    }
                }
            }

            await MainActor.run {
                if urls.isEmpty {
                    self.cancel()
                } else {
                    // TODO: show mini upload UI, then queue via shared app group container
                    self.showUploadConfirmation(urls: urls)
                }
            }
        }
    }

    private func showUploadConfirmation(urls: [URL]) {
        let names = urls.map { $0.lastPathComponent }.joined(separator: ", ")
        let alert = UIAlertController(
            title: "Save to Vault",
            message: "Upload \(urls.count) file(s) to your Vault?\n\(names)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Upload", style: .default) { _ in
            // TODO: write to shared app group container for main app to pick up
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            self.cancel()
        })
        present(alert, animated: true)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "com.katafract.vault", code: 0))
    }
}
