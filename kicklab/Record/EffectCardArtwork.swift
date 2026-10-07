import SwiftUI
import UIKit

/// Decode picker artwork at its displayed resolution. Image(name).resizable()
/// still decodes the full catalog image (up to 1024 × 1536 for these cards).
struct EffectCardArtwork: View {
    let name: String
    let size: CGSize
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?

    private var pixels: CGSize {
        CGSize(width: max(1, ceil(size.width * displayScale)),
               height: max(1, ceil(size.height * displayScale)))
    }
    private var cacheKey: String { "\(name):\(Int(pixels.width))x\(Int(pixels.height))" }
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 8_000_000
        return cache
    }()

    var body: some View {
        Group {
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
            else { Color.clear }
        }
        .task(id: cacheKey) {
            let key = cacheKey as NSString
            if let cached = Self.cache.object(forKey: key) { thumbnail = cached; return }
            guard size.width > 0, size.height > 0, let source = UIImage(named: name) else { return }
            // Preserve aspect-fill cropping: the decoded image must cover both
            // dimensions, rather than fit inside a differently shaped card.
            let ratio = min(1, max(pixels.width / source.size.width, pixels.height / source.size.height))
            let target = CGSize(width: source.size.width * ratio, height: source.size.height * ratio)
            guard let image = await source.byPreparingThumbnail(ofSize: target), !Task.isCancelled else { return }
            let bytes = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
            Self.cache.setObject(image, forKey: key, cost: bytes)
            thumbnail = image
        }
    }
}
