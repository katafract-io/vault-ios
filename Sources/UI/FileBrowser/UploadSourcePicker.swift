import SwiftUI
import PhotosUI

/// Upload source selection menu.
enum UploadSource {
    case scan
    case camera
    case photoLibrary
    case files

    var label: String {
        switch self {
        case .scan:
            return "Scan Document"
        case .camera:
            return "Take Photo"
        case .photoLibrary:
            return "Choose Photos"
        case .files:
            return "Choose Files"
        }
    }

    var icon: String {
        switch self {
        case .scan:
            return "doc.viewfinder"
        case .camera:
            return "camera"
        case .photoLibrary:
            return "photo.on.rectangle"
        case .files:
            return "folder"
        }
    }
}

/// Wrapper for PHPickerViewController to select photos/videos.
struct PhotoPickerView: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0  // unlimited
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, dismiss: dismiss)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([URL]) -> Void
        let dismiss: DismissAction

        init(onPick: @escaping ([URL]) -> Void, dismiss: DismissAction) {
            self.onPick = onPick
            self.dismiss = dismiss
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            dismiss()

            var urls: [URL] = []
            let group = DispatchGroup()

            for result in results {
                group.enter()
                let isVideo = result.itemProvider.hasItemConformingToTypeIdentifier("public.movie")
                let typeId = isVideo ? "public.movie" : "public.image"

                result.itemProvider.loadFileRepresentation(forTypeIdentifier: typeId) { url, error in
                    if let url = url {
                        // Copy to temp location since PHPicker gives us a temporary URL
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension(url.pathExtension)
                        do {
                            try FileManager.default.copyItem(at: url, to: tempURL)
                            urls.append(tempURL)
                        } catch {
                            urls.append(url)  // Fallback to original
                        }
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                self.onPick(urls)
            }
        }
    }
}

/// Wrapper for UIImagePickerController (camera).
struct CameraPickerView: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image", "public.movie"]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, dismiss: dismiss)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: ([URL]) -> Void
        let dismiss: DismissAction

        init(onPick: @escaping ([URL]) -> Void, dismiss: DismissAction) {
            self.onPick = onPick
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            dismiss()

            if let mediaURL = info[.mediaURL] as? URL {
                onPick([mediaURL])
            } else if let image = info[.originalImage] as? UIImage,
                      let data = image.jpegData(compressionQuality: 0.9) {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                try? data.write(to: tempURL)
                onPick([tempURL])
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
