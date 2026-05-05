import SwiftUI
import PhotosUI

struct UploadSourceMenuSheet: View {
    var onUpload: ([URL]) -> Void
    @Environment(\.dismiss) var dismiss

    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Section {
                    Button(action: { showCamera = true }) {
                        HStack(spacing: 12) {
                            Image(systemName: "camera.fill")
                                .frame(width: 24)
                            Text("Take Photo")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundColor(.primary)

                    Divider()

                    Button(action: { showPhotoPicker = true }) {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle")
                                .frame(width: 24)
                            Text("Choose Photos")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundColor(.primary)

                    Divider()

                    Button(action: { showDocumentPicker = true }) {
                        HStack(spacing: 12) {
                            Image(systemName: "doc")
                                .frame(width: 24)
                            Text("Choose Files")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundColor(.primary)

                    Divider()

                    HStack(spacing: 12) {
                        Image(systemName: "doc.text.viewfinder")
                            .frame(width: 24)
                        Text("Scan Document")
                        Spacer()
                    }
                    .foregroundColor(.gray)
                    .opacity(0.6)
                } header: {
                    Text("Select a source for your upload")
                        .font(.headline)
                }

                Spacer()
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showCamera) {
            ImagePickerView(sourceType: .camera) { urls in
                onUpload(urls)
                dismiss()
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PHPickerViewRepresentable { urls in
                onUpload(urls)
                dismiss()
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { urls in
                onUpload(urls)
                dismiss()
            }
        }
    }
}

struct PHPickerViewRepresentable: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0 // Unlimited selection
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
            var urls: [URL] = []
            let group = DispatchGroup()

            for result in results {
                group.enter()
                if result.itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                        defer { group.leave() }
                        if let url = url {
                            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + (url.lastPathComponent))
                            try? FileManager.default.copyItem(at: url, to: tempURL)
                            urls.append(tempURL)
                        }
                    }
                } else if result.itemProvider.hasItemConformingToTypeIdentifier(UTType.video.identifier) {
                    result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.video.identifier) { url, error in
                        defer { group.leave() }
                        if let url = url {
                            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + (url.lastPathComponent))
                            try? FileManager.default.copyItem(at: url, to: tempURL)
                            urls.append(tempURL)
                        }
                    }
                } else {
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                self.onPick(urls)
                self.dismiss()
            }
        }
    }
}

struct ImagePickerView: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType
    var onPick: ([URL]) -> Void
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.mediaTypes = ["public.image"]
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
            if let originalImage = info[.originalImage] as? UIImage {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                if let jpegData = originalImage.jpegData(compressionQuality: 0.8) {
                    try? jpegData.write(to: tempURL)
                    onPick([tempURL])
                }
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
