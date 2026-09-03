import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageEncodingService {
    public static func image(
        for url: URL,
        selection: AIImageSelection? = nil,
        maxPixelSize: Int = 2048
    ) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageEncodingError.invalidImage
        }

        let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
            ] as CFDictionary
        ) ?? CGImageSourceCreateImageAtIndex(source, 0, nil)

        guard let image else {
            throw ImageEncodingError.invalidImage
        }
        guard let selection else {
            return image
        }

        let clamped = selection.clamped
        guard clamped.width > 0, clamped.height > 0 else {
            throw ImageEncodingError.invalidSelection
        }

        // The canvas stores selection coordinates from top to bottom; CGImage uses a bottom-left origin.
        let cropRect = CGRect(
            x: clamped.x * Double(image.width),
            y: (1 - clamped.y - clamped.height) * Double(image.height),
            width: clamped.width * Double(image.width),
            height: clamped.height * Double(image.height)
        ).integral.intersection(CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        ))

        guard cropRect.width >= 1, cropRect.height >= 1,
              let cropped = image.cropping(to: cropRect) else {
            throw ImageEncodingError.invalidSelection
        }
        return cropped
    }

    public static func jpegData(
        for url: URL,
        selection: AIImageSelection? = nil,
        maxPixelSize: Int = 2048,
        quality: Double = 0.88
    ) throws -> Data {
        let image = try image(for: url, selection: selection, maxPixelSize: maxPixelSize)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageEncodingError.encoderUnavailable
        }

        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: min(1, max(0.1, quality))] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ImageEncodingError.encodingFailed
        }
        return data as Data
    }

    public static func pngData(
        for url: URL,
        selection: AIImageSelection? = nil,
        maxPixelSize: Int = 2048
    ) throws -> Data {
        let image = try image(for: url, selection: selection, maxPixelSize: maxPixelSize)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageEncodingError.encoderUnavailable
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageEncodingError.encodingFailed
        }
        return data as Data
    }
}

public enum ImageEncodingError: LocalizedError {
    case invalidImage
    case invalidSelection
    case encoderUnavailable
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无法读取图片。"
        case .invalidSelection:
            return "局部选区无效。"
        case .encoderUnavailable:
            return "系统图片编码器不可用。"
        case .encodingFailed:
            return "无法准备 AI 图片数据。"
        }
    }
}
