import SwiftUI
import UIKit
import Photos

/// Fetches and renders a thumbnail for a PHAsset identified by localIdentifier,
/// or renders a shield placeholder for cloud-only assets (in vault but deleted from device).
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
    let assetLocalIdentifier: String?
    let targetSize: CGSize
    let contentMode: PHImageContentMode
    let isCloudOnly: Bool

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    init(assetLocalIdentifier: String?,
         targetSize: CGSize = CGSize(width: 200, height: 200),
         contentMode: PHImageContentMode = .aspectFill,
         isCloudOnly: Bool = false) {
        self.assetLocalIdentifier = assetLocalIdentifier
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.isCloudOnly = isCloudOnly
    }

    var body: some View {
        ZStack {
            // Placeholder layer — always present, stays behind the image.
            // Keeps cell geometry stable during PHImageManager's two-phase
            // delivery (low-res, then high-res).
            Color(.systemGray5)

            if isCloudOnly {
                // Cloud-only asset: show shield icon placeholder
                Image(systemName: "shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            } else if ScreenshotMode.isActive, let localId = assetLocalIdentifier {
                // Render deterministic gradient directly at body time — bypasses the
                // PHAsset → requestImage → @State async cycle which races the snapshot.
                Image(uiImage: Self.mockThumbnail(for: localId, size: targetSize))
                    .resizable()
                    .aspectRatio(
                        contentMode: contentMode == .aspectFill ? .fill : .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transaction { $0.animation = nil }
            } else if let image {
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
        guard image == nil, !isCloudOnly else { return }
        guard let localId = assetLocalIdentifier else { return }
        // In screenshot mode skip PHAsset lookup entirely — the simulator
        // photo library has no real images, so requestImage returns a gray
        // placeholder regardless of whether the asset record exists.
        if ScreenshotMode.isActive {
            DispatchQueue.main.async {
                self.image = Self.mockThumbnail(for: localId, size: self.targetSize)
            }
            return
        }
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [localId], options: nil)
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

    private static func mockThumbnail(for id: String, size: CGSize) -> UIImage {
        // Prefer bundled landscape photos (mock_photo_1...mock_photo_6) so the
        // screenshot grid shows real-looking photography — fake data, real
        // screens. Deterministic per asset id; gradient below stays as fallback.
        let idx = (abs(id.hashValue) % 6) + 1
        if let photo = UIImage(named: "mock_photo_\(idx)") {
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { _ in
                let scale = max(size.width / photo.size.width, size.height / photo.size.height)
                let w = photo.size.width * scale
                let h = photo.size.height * scale
                photo.draw(in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
            }
        }
        let palette: [UIColor] = [
            UIColor(red: 0.22, green: 0.42, blue: 0.78, alpha: 1),  // sapphire
            UIColor(red: 0.20, green: 0.62, blue: 0.45, alpha: 1),  // teal
            UIColor(red: 0.72, green: 0.35, blue: 0.20, alpha: 1),  // terracotta
            UIColor(red: 0.48, green: 0.28, blue: 0.70, alpha: 1),  // violet
            UIColor(red: 0.22, green: 0.52, blue: 0.42, alpha: 1),  // forest
            UIColor(red: 0.65, green: 0.30, blue: 0.42, alpha: 1),  // rose
            UIColor(red: 0.28, green: 0.46, blue: 0.62, alpha: 1),  // slate
            UIColor(red: 0.70, green: 0.50, blue: 0.18, alpha: 1),  // amber
            UIColor(red: 0.32, green: 0.58, blue: 0.35, alpha: 1),  // sage
            UIColor(red: 0.55, green: 0.25, blue: 0.60, alpha: 1),  // plum
        ]
        let base = palette[abs(id.hashValue) % palette.count]
        let lighter = base.withAlphaComponent(0.6)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cgCtx = ctx.cgContext
            // Gradient fill
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [base.cgColor, lighter.cgColor] as CFArray,
                locations: [0.0, 1.0]
            )!
            cgCtx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: size.height),
                options: []
            )
            // Mountain-silhouette watermark
            UIColor.white.withAlphaComponent(0.18).setFill()
            let m = min(size.width, size.height)
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: m * 0.25, y: size.height * 0.45))
            path.addLine(to: CGPoint(x: m * 0.45, y: size.height * 0.62))
            path.addLine(to: CGPoint(x: m * 0.60, y: size.height * 0.30))
            path.addLine(to: CGPoint(x: m * 0.80, y: size.height * 0.55))
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.close()
            path.fill()
            // Sun circle
            UIColor.white.withAlphaComponent(0.22).setFill()
            let sunR = m * 0.10
            let sunCenter = CGPoint(x: size.width * 0.72, y: size.height * 0.22)
            UIBezierPath(ovalIn: CGRect(x: sunCenter.x - sunR, y: sunCenter.y - sunR,
                                        width: sunR * 2, height: sunR * 2)).fill()
        }
    }

    private func cancel() {
        if let requestID {
            PHImageManager.default().cancelImageRequest(requestID)
            self.requestID = nil
        }
    }
}
