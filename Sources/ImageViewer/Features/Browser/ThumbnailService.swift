import AppKit
import ImageViewerCore

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    private init() {
    }

    func image(for url: URL) async -> NSImage? {
        let maxPixelSize = 320
        let cgImage: CGImage?
        if let memoryImage = await ImageDecodeCache.shared.cachedImage(
            for: url,
            maxPixelSize: maxPixelSize
        ) {
            cgImage = memoryImage
        } else if let diskImage = await DiskThumbnailCache.shared.image(
            for: url,
            maxPixelSize: maxPixelSize
        ) {
            await ImageDecodeCache.shared.store(
                diskImage,
                for: url,
                maxPixelSize: maxPixelSize
            )
            cgImage = diskImage
        } else {
            let decodedImage = await ImageDecodeCache.shared.image(
                for: url,
                maxPixelSize: maxPixelSize,
                priority: .current
            )
            if let decodedImage {
                await DiskThumbnailCache.shared.store(
                    decodedImage,
                    for: url,
                    maxPixelSize: maxPixelSize
                )
            }
            cgImage = decodedImage
        }

        guard let cgImage else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    func removeAll() {
        Task {
            await ImageDecodeCache.shared.removeAll()
            await DiskThumbnailCache.shared.removeAll()
        }
    }
}
