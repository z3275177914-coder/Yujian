import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageExportFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG"
    case png = "PNG"
    case heic = "HEIC"
    case tiff = "TIFF"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .jpeg:
            return "jpg"
        case .png:
            return "png"
        case .heic:
            return "heic"
        case .tiff:
            return "tiff"
        }
    }

    public var displayName: String {
        switch self {
        case .jpeg:
            return "JPEG（有损）"
        case .png:
            return "PNG（无损）"
        case .heic:
            return "HEIC（高效）"
        case .tiff:
            return "TIFF（无损）"
        }
    }

    public var typeIdentifier: String {
        switch self {
        case .jpeg:
            return UTType.jpeg.identifier
        case .png:
            return UTType.png.identifier
        case .heic:
            return UTType.heic.identifier
        case .tiff:
            return UTType.tiff.identifier
        }
    }

    public static func from(fileExtension: String) -> ImageExportFormat? {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        default: return nil
        }
    }
}

public enum ImageMetadataPolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    case preserve
    case stripPrivateLocation

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .preserve: return "保留元数据"
        case .stripPrivateLocation: return "剥离 GPS 位置"
        }
    }
}

public struct ImageExportOptions: Sendable {
    public var width: Int?
    public var height: Int?
    public var keepAspectRatio: Bool
    public var quality: Double
    public var metadataPolicy: ImageMetadataPolicy

    public init(
        width: Int? = nil,
        height: Int? = nil,
        keepAspectRatio: Bool = true,
        quality: Double = 0.9,
        metadataPolicy: ImageMetadataPolicy = .preserve
    ) {
        self.width = width
        self.height = height
        self.keepAspectRatio = keepAspectRatio
        self.quality = quality
        self.metadataPolicy = metadataPolicy
    }
}

public enum ImageExportService {
    public static func export(
        sourceURL: URL,
        destinationURL: URL,
        format: ImageExportFormat,
        options: ImageExportOptions = ImageExportOptions(),
        recipe: EditRecipe = .empty
    ) throws {
        let signpostID = PerformanceLog.begin("ExportImage")
        defer {
            PerformanceLog.end("ExportImage", signpostID: signpostID)
        }

        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".imageviewer-export-(UUID().uuidString).tmp")
        do {
            try writeExport(
                sourceURL: sourceURL,
                destinationURL: temporaryURL,
                format: format,
                options: options,
                recipe: recipe
            )
            try atomicallyReplace(temporaryURL, at: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func writeExport(
        sourceURL: URL,
        destinationURL: URL,
        format: ImageExportFormat,
        options: ImageExportOptions,
        recipe: EditRecipe
    ) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let rawImage = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            throw ImageExportError.invalidSource
        }

        let orientation = (sourceProperties.object(forKey: kCGImagePropertyOrientation) as? NSNumber)?.intValue ?? 1
        let sourceImage = try normalizedOrientation(rawImage, orientation: orientation)
        let transformed = try renderRecipe(sourceImage, recipe: recipe)
        let outputImage = try resizedImage(
            transformed,
            width: options.width,
            height: options.height,
            keepAspectRatio: options.keepAspectRatio
        )

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            format.typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw ImageExportError.destinationUnavailable
        }

        var destinationProperties = metadataProperties(
            sourceProperties,
            policy: options.metadataPolicy
        )
        destinationProperties[kCGImagePropertyOrientation] = 1
        if format == .jpeg || format == .heic {
            destinationProperties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0.1, options.quality))
        }
        CGImageDestinationAddImage(destination, outputImage, destinationProperties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageExportError.writeFailed
        }
    }

    private static func renderRecipe(
        _ sourceImage: CGImage,
        recipe: EditRecipe
    ) throws -> CGImage {
        var output = sourceImage
        for operation in recipe.enabledOperations {
            switch operation.kind {
            case .brightness:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(brightness: operation.value)
                ) ?? output
            case .contrast:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(contrast: operation.value)
                ) ?? output
            case .saturation:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(saturation: operation.value)
                ) ?? output
            case .sharpness:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(sharpness: operation.value)
                ) ?? output
            case .exposure:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(exposure: operation.value)
                ) ?? output
            case .highlights:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(highlights: operation.value)
                ) ?? output
            case .shadows:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(shadows: operation.value)
                ) ?? output
            case .temperature:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(temperature: operation.value)
                ) ?? output
            case .tint:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(tint: operation.value)
                ) ?? output
            case .crop:
                if let cropRect = operation.cropRect,
                   let cropped = ImageAdjustmentService.crop(output, to: cropRect) {
                    output = cropped
                }
            case .rotate, .straighten:
                output = try transformedImage(
                    output,
                    rotationDegrees: operation.value,
                    flipHorizontally: false
                )
            case .flipHorizontal:
                if operation.value > 0.5 {
                    output = try transformedImage(
                        output,
                        rotationDegrees: 0,
                        flipHorizontally: true
                    )
                }
            }
        }
        return output
    }

    private static func normalizedOrientation(
        _ image: CGImage,
        orientation: Int
    ) throws -> CGImage {
        guard orientation != 1 else {
            return image
        }
        let ciImage = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let normalized = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw ImageExportError.transformFailed
        }
        return normalized
    }

    private static func transformedImage(
        _ image: CGImage,
        rotationDegrees: Double,
        flipHorizontally: Bool
    ) throws -> CGImage {
        let degrees = rotationDegrees.isFinite ? rotationDegrees : 0
        guard degrees.truncatingRemainder(dividingBy: 360) != 0 || flipHorizontally else {
            return image
        }

        var transform = CGAffineTransform.identity
        if flipHorizontally {
            transform = transform.scaledBy(x: -1, y: 1)
        }
        transform = transform.rotated(by: degrees * .pi / 180)

        let ciImage = CIImage(cgImage: image).transformed(by: transform)
        let extent = ciImage.extent.integral
        let translated = ciImage.transformed(
            by: CGAffineTransform(
                translationX: -extent.minX,
                y: -extent.minY
            )
        )
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let transformed = context.createCGImage(
            translated,
            from: CGRect(origin: .zero, size: extent.size)
        ) else {
            throw ImageExportError.transformFailed
        }
        return transformed
    }

    private static func metadataProperties(
        _ sourceProperties: NSDictionary,
        policy: ImageMetadataPolicy
    ) -> [CFString: Any] {
        var properties = (sourceProperties as? [CFString: Any]) ?? [:]
        properties.removeValue(forKey: kCGImagePropertyPixelWidth)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight)
        properties.removeValue(forKey: kCGImagePropertyFileSize)
        if policy == .stripPrivateLocation {
            properties.removeValue(forKey: kCGImagePropertyGPSDictionary)
        }
        return properties
    }

    private static func atomicallyReplace(_ temporaryURL: URL, at destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    public static func batchExport(
        assets: [ImageAsset],
        destinationDirectory: URL,
        format: ImageExportFormat,
        options: ImageExportOptions = ImageExportOptions(),
        recipe: EditRecipe = .empty
    ) throws -> Int {
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        var exportedCount = 0
        for asset in assets {
            let baseName = asset.url.deletingPathExtension().lastPathComponent
            let destinationURL = uniqueURL(
                in: destinationDirectory,
                baseName: baseName,
                fileExtension: format.fileExtension
            )
            try export(
                sourceURL: asset.url,
                destinationURL: destinationURL,
                format: format,
                options: options,
                recipe: recipe
            )
            exportedCount += 1
        }
        return exportedCount
    }

    private static func resizedImage(
        _ image: CGImage,
        width: Int?,
        height: Int?,
        keepAspectRatio: Bool
    ) throws -> CGImage {
        guard width != nil || height != nil else {
            return image
        }

        let sourceWidth = image.width
        let sourceHeight = image.height
        let targetSize: (width: Int, height: Int)

        if keepAspectRatio {
            let requestedWidth = width ?? Int(Double(sourceWidth) * Double(height ?? sourceHeight) / Double(sourceHeight))
            let requestedHeight = height ?? Int(Double(sourceHeight) * Double(width ?? sourceWidth) / Double(sourceWidth))
            let widthScale = Double(requestedWidth) / Double(sourceWidth)
            let heightScale = Double(requestedHeight) / Double(sourceHeight)
            let scale = min(widthScale, heightScale)
            targetSize = (
                max(1, Int(Double(sourceWidth) * scale)),
                max(1, Int(Double(sourceHeight) * scale))
            )
        } else {
            targetSize = (
                max(1, width ?? sourceWidth),
                max(1, height ?? sourceHeight)
            )
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: targetSize.width,
                height: targetSize.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ImageExportError.resizeFailed
        }

        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height)
        )
        guard let outputImage = context.makeImage() else {
            throw ImageExportError.resizeFailed
        }
        return outputImage
    }

    private static func uniqueURL(
        in directory: URL,
        baseName: String,
        fileExtension: String
    ) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(fileExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(suffix).\(fileExtension)")
            suffix += 1
        }
        return candidate
    }
}

public enum ImageExportError: LocalizedError {
    case invalidSource
    case destinationUnavailable
    case resizeFailed
    case transformFailed
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "无法读取源图片。"
        case .destinationUnavailable:
            return "无法创建导出文件。"
        case .resizeFailed:
            return "无法调整图片大小。"
        case .transformFailed:
            return "无法应用图片方向或编辑变换。"
        case .writeFailed:
            return "无法写入导出文件。"
        }
    }
}
