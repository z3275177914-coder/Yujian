import CoreGraphics
import Foundation
import ImageViewerCore

@MainActor
final class DecodedImageCache {
    static let shared = DecodedImageCache()

    private init() {
    }

    func image(for url: URL, maxPixelSize: Int?) async -> CGImage? {
        await ImageDecodeCache.shared.image(
            for: url,
            maxPixelSize: maxPixelSize,
            priority: .current
        )
    }

    func prefetch(
        urls: [URL],
        maxPixelSize: Int,
        direction: ImagePrefetchDirection
    ) {
        Task {
            await ImageDecodeCache.shared.prefetch(
                urls: urls,
                maxPixelSize: maxPixelSize,
                direction: direction
            )
        }
    }

    func cancelPrefetch() {
        Task {
            await ImageDecodeCache.shared.cancelPrefetch()
        }
    }

    func removeAll() {
        Task {
            await ImageDecodeCache.shared.removeAll()
        }
    }
}
