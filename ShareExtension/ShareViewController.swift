import UIKit
import Social
import UniformTypeIdentifiers

/// Vaultyx Share Extension.
///
/// Receives files from other apps via the iOS share sheet and writes them
/// into the App Group import inbox. The main Vaultyx app picks them up the
/// next time the user opens it (drained on `.active` scenePhase) and runs
/// them through the normal import → encrypt → upload pipeline.
///
/// We DO NOT chunk/encrypt/upload here because:
///   * Share extensions get ~5-30s of execution time before iOS terminates.
///   * Upload requires the user's master key, which is gated behind biometric
///     unlock in the main app — share extension can't access it without the
///     user re-authing inside the extension UI, and we don't want to expose
///     keychain biometric prompts in the share-sheet flow.
///
/// Inbox path: AppGroup `group.com.katafract.vault` /ImportInbox/<uuid>.<ext>
/// Sidecar:    same dir, <uuid>.json with { originalName, parentFolderId }
class ShareViewController: UIViewController {

    private static let appGroupID = "group.com.katafract.vault"

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
            // Materialize each attachment as either a file URL or raw Data,
            // along with the best-guess original filename.
            var staged: [(originalName: String, sourceURL: URL?, data: Data?)] = []
            for item in extensionItems {
                for provider in (item.attachments ?? []) {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        if let url = try? await provider.loadItem(
                            forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                            staged.append((url.lastPathComponent, url, nil))
                        }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                        if let data = try? await provider.loadItem(
                            forTypeIdentifier: UTType.data.identifier) as? Data {
                            let name = provider.suggestedName ?? "shared-\(UUID().uuidString.prefix(8))"
                            staged.append((name, nil, data))
                        }
                    }
                }
            }

            await MainActor.run {
                if staged.isEmpty {
                    self.cancel()
                } else {
                    self.showUploadConfirmation(staged: staged)
                }
            }
        }
    }

    private func showUploadConfirmation(
        staged: [(originalName: String, sourceURL: URL?, data: Data?)]
    ) {
        let names = staged.map { $0.originalName }.joined(separator: ", ")
        let alert = UIAlertController(
            title: "Save to Vault",
            message: "Upload \(staged.count) file(s) to your Vault?\n\(names)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Upload", style: .default) { [weak self] _ in
            self?.dropIntoInbox(staged)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.cancel()
        })
        present(alert, animated: true)
    }

    /// Copy each staged item into the App Group inbox along with a sidecar
    /// describing the original filename. The main app drains the inbox on
    /// next launch / scene-active.
    private func dropIntoInbox(
        _ staged: [(originalName: String, sourceURL: URL?, data: Data?)]
    ) {
        guard let inbox = sharedInboxURL() else {
            self.cancel()
            return
        }

        for item in staged {
            let stem = UUID().uuidString
            let ext = (item.originalName as NSString).pathExtension
            let fileURL = inbox.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")

            do {
                if let src = item.sourceURL {
                    // Security-scoped resource access for files coming from
                    // sandboxed senders (Files app, etc.)
                    let scoped = src.startAccessingSecurityScopedResource()
                    defer { if scoped { src.stopAccessingSecurityScopedResource() } }
                    try FileManager.default.copyItem(at: src, to: fileURL)
                } else if let data = item.data {
                    try data.write(to: fileURL, options: [.atomic])
                } else {
                    continue
                }
                try? (fileURL as NSURL).setResourceValue(
                    URLFileProtection.complete, forKey: .fileProtectionKey)

                // Sidecar — JSON with the original filename. Parent folder
                // is left nil (drops into vault root); future UI work can
                // add a folder picker before invoking this code path.
                let sidecarURL = inbox.appendingPathComponent("\(stem).json")
                let sidecar: [String: Any] = [
                    "originalName": item.originalName
                    // parentFolderId omitted ⇒ root
                ]
                let sidecarData = try JSONSerialization.data(withJSONObject: sidecar)
                try sidecarData.write(to: sidecarURL, options: [.atomic])
                try? (sidecarURL as NSURL).setResourceValue(
                    URLFileProtection.complete, forKey: .fileProtectionKey)
            } catch {
                // Best-effort — keep going on partial failures.
                continue
            }
        }

        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func sharedInboxURL() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { return nil }
        let dir = container.appendingPathComponent("ImportInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "com.katafract.vault", code: 0))
    }
}
