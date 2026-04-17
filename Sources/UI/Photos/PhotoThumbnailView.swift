import SwiftUI
import UIKit
import Photos

/// Fetches and renders a thumbnail for a PHAsset identified by localIdentifier.
///
/// Owns its own frame: callers supply `targetSize` and get back a view that
/// clips to that size. This avoids the nested-aspectRatio layout thrash that
/// happens when the outer view forces `.aspectRatio(1, contentMode: .fill)`
/// and the inner Image arrives at its natural ratio (fast flash of correct
/// shape, then squeeze to square).
///
/// The placeholder and loaded Image share the same clipped frame so there's
/// no geometry change between states, and we explicitly disable transition
/// animations on the image swap.
struct PhotoThumbnailView: View {
    let assetLocalIdentifier: String
    let targetSize: CGSize
    let contentMode: PHImageContentMode

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    init(assetLocalIdentifier: String,
         targetSize: CGSize = CGSize(width: 200, height: 200),
         contentMode: PHImageContentMode = .aspectFill) {
        self.assetLocalIdentifier = assetLocalIdentifier
        self.targetSize = targetSize
        self.contentMode = contentMode
    }

    var body: some View {
        ZStack {
            // Placeholder layer — always present, stays behind the image.
            // Keeps cell geometry stable during PHImageManager's two-phase
            // delivery (low-res, then high-res).
            Color(.systemGray5)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(
                        contentMode: contentMode == .aspectFill ? .fill : .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transaction { $0.animation = nil }  // suppress fade-in thrash
            }
        }
        .clipped()
        .onAppear(perform: fetch)
        .onDisappear(perform: cancel)
    }

    private func fetch() {
        guard image == nil else { return }
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetLocalIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else { return }

        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        // Single high-quality delivery avoids the low-res → high-res swap
        // that caused visible re-layouts. Worth the slight load delay.
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .exact

        let scale = UIScreen.main.scale
        let scaled = CGSize(width: targetSize.width * scale,
                            height: targetSize.height * scale)

        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: scaled,
            contentMode: contentMode,
            options: opts
        ) { result, _ in
            if let result {
                // State update must be on main; explicitly dispatch.
                DispatchQueue.main.async { self.image = result }
            }
        }
    }

    private func cancel() {
        if let requestID {
            PHImageManager.default().cancelImageRequest(requestID)
            self.requestID = nil
        }
    }
}
