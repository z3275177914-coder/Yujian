import Foundation

public struct AIImageInput: Sendable {
    public let url: URL
    public let source: AIInputSource
    public let byteCount: Int
    public let isTemporary: Bool

    public init(
        url: URL,
        source: AIInputSource,
        byteCount: Int,
        isTemporary: Bool
    ) {
        self.url = url
        self.source = source
        self.byteCount = byteCount
        self.isTemporary = isTemporary
    }
}

public enum AIInputPreparationError: LocalizedError, Sendable {
    case invalidSelection
    case cannotCreateTemporaryFile
    case imageTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidSelection:
            return "请先在画布上选择有效的图片区域。"
        case .cannotCreateTemporaryFile:
            return "无法准备 AI 临时图片文件。"
        case .imageTooLarge:
            return "图片压缩后仍超过当前接口允许的大小。"
        }
    }
}

public enum AIInputService {
    public static func prepare(
        sourceURL: URL,
        source: AIInputSource,
        recipe: EditRecipe,
        selection: AIImageSelection?,
        action: AIAction,
        capabilities: AIProviderCapabilities
    ) throws -> AIImageInput {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw AIInputPreparationError.cannotCreateTemporaryFile
        }

        let needsSelection = source == .selection || selection != nil
        if source == .original, !needsSelection,
           let byteCount = fileByteCount(sourceURL),
           byteCount <= capabilities.maxBytes {
            return AIImageInput(
                url: sourceURL,
                source: source,
                byteCount: byteCount,
                isTemporary: false
            )
        }

        if source == .selection && selection == nil {
            throw AIInputPreparationError.invalidSelection
        }

        var preparedRecipe = source == .original ? EditRecipe.empty : recipe
        if let selection, selection.clamped.width > 0, selection.clamped.height > 0 {
            preparedRecipe.operations.append(
                .stable(
                    .crop,
                    cropRect: EditCropRect(
                        x: selection.clamped.x,
                        y: selection.clamped.y,
                        width: selection.clamped.width,
                        height: selection.clamped.height
                    )
                )
            )
        } else if needsSelection {
            throw AIInputPreparationError.invalidSelection
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageViewerAI", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw AIInputPreparationError.cannotCreateTemporaryFile
        }

        let format = action == .edit ? capabilities.editingFormat : capabilities.analysisFormat
        let temporaryURL = directory.appendingPathComponent(
            "input-\(UUID().uuidString).\(format.fileExtension)"
        )
        let targetSizes = [
            capabilities.maxPixelSize,
            max(512, capabilities.maxPixelSize / 2),
            max(256, capabilities.maxPixelSize / 4)
        ].uniqued()

        for targetSize in targetSizes {
            do {
                try ImageExportService.export(
                    sourceURL: sourceURL,
                    destinationURL: temporaryURL,
                    format: format,
                    options: ImageExportOptions(
                        width: targetSize,
                        height: targetSize,
                        keepAspectRatio: true,
                        quality: action == .edit ? 0.95 : 0.86,
                        metadataPolicy: .stripPrivateLocation
                    ),
                    recipe: preparedRecipe
                )
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw AIInputPreparationError.cannotCreateTemporaryFile
            }

            if let byteCount = fileByteCount(temporaryURL), byteCount <= capabilities.maxBytes {
                return AIImageInput(
                    url: temporaryURL,
                    source: source,
                    byteCount: byteCount,
                    isTemporary: true
                )
            }
        }

        try? FileManager.default.removeItem(at: temporaryURL)
        throw AIInputPreparationError.imageTooLarge
    }

    public static func cleanup(_ input: AIImageInput) {
        guard input.isTemporary else { return }
        try? FileManager.default.removeItem(at: input.url)
    }

    private static func fileByteCount(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }
}

private extension Array where Element: Equatable {
    func uniqued() -> [Element] {
        reduce(into: []) { result, element in
            if !result.contains(element) {
                result.append(element)
            }
        }
    }
}
