import UIKit
import AVFoundation
import CryptoKit

/// On-device thumbnail generation and encryption.
/// Generates 3 sizes (256, 512, 1024px longest edge), JPEG quality 0.8, encrypted per-file.
struct ThumbnailGenerator {

    enum Size {
        case small   // 256px
        case medium  // 512px
        case large   // 1024px

        var pixelSize: Int {
            switch self {
            case .small: return 256
            case .medium: return 512
            case .large: return 1024
            }
        }
    }

    /// Generate encrypted thumbnails from an image file.
    /// Returns a dictionary: [size label -> (encrypted bytes, size px)].
    /// Throws if the file can't be loaded or image generation fails.
    static func generateEncryptedThumbnails(
        sourceURL: URL,
        thumbnailKey: SymmetricKey,
        mimeType: String
    ) throws -> [String: (encryptedData: Data, sizePixels: Int)] {
        let sourceImage: UIImage

        // Load image or extract frame from video.
        if mimeType.hasPrefix("video/") {
            sourceImage = try extractVideoFrame(from: sourceURL)
        } else {
            guard let img = UIImage(contentsOfFile: sourceURL.path) else {
                throw ThumbnailError.invalidImage
            }
            sourceImage = img
        }

        var result: [String: (encryptedData: Data, sizePixels: Int)] = [:]

        for size: Size in [.small, .medium, .large] {
            let thumbnail = resizeImage(sourceImage, to: size)
            guard let jpegData = thumbnail.jpegData(compressionQuality: 0.8) else {
                throw ThumbnailError.jpegEncodeFailed
            }

            let encrypted = try VaultCrypto.encrypt(jpegData, key: thumbnailKey)
            let label = "thumb_\(size.pixelSize)"
            result[label] = (encrypted, size.pixelSize)
        }

        return result
    }

    /// Resize image to fit within the given size (longest edge), maintaining aspect ratio.
    private static func resizeImage(_ image: UIImage, to size: Size) -> UIImage {
        let targetSize = CGSize(width: CGFloat(size.pixelSize), height: CGFloat(size.pixelSize))

        let widthRatio = targetSize.width / image.size.width
        let heightRatio = targetSize.height / image.size.height
        let scale = min(widthRatio, heightRatio)

        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Extract first frame from a video file for thumbnail.
    private static func extractVideoFrame(from url: URL) throws -> UIImage {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let time = CMTime(value: 0, timescale: 1)
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        return UIImage(cgImage: cgImage)
    }

    enum ThumbnailError: LocalizedError {
        case invalidImage
        case jpegEncodeFailed
        case videoExtractionFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                return "Could not load image"
            case .jpegEncodeFailed:
                return "Failed to encode JPEG thumbnail"
            case .videoExtractionFailed:
                return "Failed to extract video frame"
            }
        }
    }
}
