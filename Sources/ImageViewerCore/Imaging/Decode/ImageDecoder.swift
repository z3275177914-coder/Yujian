import AppKit
import CoreImage
import Foundation
import ImageIO

public struct DecodedAnimation: Sendable {
    public let frames: [CGImage]
    public let durations: [TimeInterval]

    public init(frames: [CGImage], durations: [TimeInterval]) {
        self.frames = frames
        self.durations = durations
    }
}

public enum ImageDecoder {
    public static func decodeCGImage(url: URL, maxPixelSize: Int?) -> CGImage? {
        let signpostID = PerformanceLog.begin("DecodeImage")
        defer {
            PerformanceLog.end("DecodeImage", signpostID: signpostID)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        if let maxPixelSize {
            let options: CFDictionary = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                // Materialize the interactive bitmap before it reaches
                // Core Animation. A lazily decoded CGImage can otherwise
                // make the first zoom/pan frame pay the ImageIO decode cost.
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
            ] as CFDictionary
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        }

        let options: CFDictionary = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            return nil
        }
        return normalizedOrientation(image, source: source)
    }

    public static func decodeAnimation(url: URL, maxPixelSize: Int) -> DecodedAnimation? {
        let signpostID = PerformanceLog.begin("DecodeAnimation")
        defer {
            PerformanceLog.end("DecodeAnimation", signpostID: signpostID)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else {
            return nil
        }

        let maximumFrameCount = min(frameCount, 60)
        var frames: [CGImage] = []
        var durations: [TimeInterval] = []
        frames.reserveCapacity(maximumFrameCount)
        durations.reserveCapacity(maximumFrameCount)

        for index in 0..<maximumFrameCount {
            let options: CFDictionary = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
            ] as CFDictionary

            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else {
                continue
            }
            frames.append(frame)
            durations.append(frameDuration(source: source, index: index))
        }

        guard !frames.isEmpty else {
            return nil
        }
        return DecodedAnimation(frames: frames, durations: durations)
    }

    @MainActor
    public static func loadCGImage(url: URL, maxPixelSize: Int?) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            decodeCGImage(url: url, maxPixelSize: maxPixelSize)
        }.value
    }

    @MainActor
    public static func loadAnimation(url: URL, maxPixelSize: Int) async -> DecodedAnimation? {
        await Task.detached(priority: .userInitiated) {
            decodeAnimation(url: url, maxPixelSize: maxPixelSize)
        }.value
    }

    @MainActor
    public static func loadImage(url: URL, maxPixelSize: Int?) async -> NSImage? {
        guard let image = await loadCGImage(url: url, maxPixelSize: maxPixelSize) else {
            return nil
        }

        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as NSDictionary? else {
            return 0.1
        }

        if let gif = properties.object(forKey: kCGImagePropertyGIFDictionary) as? NSDictionary {
            let unclamped = (gif.object(forKey: kCGImagePropertyGIFUnclampedDelayTime) as? NSNumber)?.doubleValue ?? 0
            let clamped = (gif.object(forKey: kCGImagePropertyGIFDelayTime) as? NSNumber)?.doubleValue ?? 0
            return max(0.02, unclamped > 0 ? unclamped : clamped > 0 ? clamped : 0.1)
        }

        return 0.1
    }

    private static func normalizedOrientation(
        _ image: CGImage,
        source: CGImageSource
    ) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
        let orientation = (properties?.object(forKey: kCGImagePropertyOrientation) as? NSNumber)?.intValue ?? 1
        guard orientation != 1,
              orientation >= 1,
              orientation <= 8 else {
            return image
        }

        let orientedImage = CIImage(cgImage: image)
            .oriented(forExifOrientation: Int32(orientation))
        let extent = orientedImage.extent.integral
        guard extent.width > 0, extent.height > 0 else {
            return image
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        return context.createCGImage(orientedImage, from: extent) ?? image
    }
}
