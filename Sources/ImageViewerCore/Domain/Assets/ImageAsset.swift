import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageAsset: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let filename: String
    public let fileExtension: String
    public let fileSize: Int64
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let createdAt: Date?
    public let modifiedAt: Date?

    public init(url: URL) {
        let normalizedURL = url.standardizedFileURL
        self.url = normalizedURL
        self.id = normalizedURL.path
        self.filename = normalizedURL.lastPathComponent
        self.fileExtension = normalizedURL.pathExtension.lowercased()

        let resourceValues = try? normalizedURL.resourceValues(forKeys: [
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey
        ])
        self.fileSize = Int64(resourceValues?.fileSize ?? 0)
        self.createdAt = resourceValues?.creationDate
        self.modifiedAt = resourceValues?.contentModificationDate

        if let source = CGImageSourceCreateWithURL(normalizedURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary? {
            let rawWidth = (properties.object(forKey: kCGImagePropertyPixelWidth) as? NSNumber)?.intValue ?? 0
            let rawHeight = (properties.object(forKey: kCGImagePropertyPixelHeight) as? NSNumber)?.intValue ?? 0
            let orientation = (properties.object(forKey: kCGImagePropertyOrientation) as? NSNumber)?.intValue ?? 1
            if Self.isTransposedOrientation(orientation) {
                self.pixelWidth = rawHeight
                self.pixelHeight = rawWidth
            } else {
                self.pixelWidth = rawWidth
                self.pixelHeight = rawHeight
            }
        } else {
            self.pixelWidth = 0
            self.pixelHeight = 0
        }
    }

    public var dimensionsLabel: String {
        guard pixelWidth > 0, pixelHeight > 0 else {
            return "未知"
        }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    public static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif",
        "png",
        "heic", "heif",
        "webp",
        "gif",
        "tif", "tiff",
        "bmp",
        "avif",
        "svg",
        "psd",
        "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2"
    ]

    public static func isSupportedImage(_ url: URL) -> Bool {
        let extensionName = url.pathExtension.lowercased()
        if supportedExtensions.contains(extensionName) {
            return true
        }

        guard let type = UTType(filenameExtension: extensionName) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private static func isTransposedOrientation(_ orientation: Int) -> Bool {
        orientation == 5 || orientation == 6 || orientation == 7 || orientation == 8
    }
}
