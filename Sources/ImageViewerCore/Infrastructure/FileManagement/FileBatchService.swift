import Foundation

public struct BatchRenameOptions: Sendable {
    public var prefix: String
    public var startNumber: Int
    public var minimumDigits: Int

    public init(
        prefix: String = "图片",
        startNumber: Int = 1,
        minimumDigits: Int = 3
    ) {
        self.prefix = prefix
        self.startNumber = startNumber
        self.minimumDigits = minimumDigits
    }
}

public enum FileBatchService {
    public static func rename(
        assets: [ImageAsset],
        options: BatchRenameOptions
    ) throws -> [URL] {
        let orderedAssets = assets.sorted {
            $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending
        }
        guard !orderedAssets.isEmpty else {
            return []
        }

        let prefix = options.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else {
            throw FileBatchError.emptyPrefix
        }

        let fileManager = FileManager.default
        let directory = orderedAssets[0].url.deletingLastPathComponent()
        let originalURLs = Set(orderedAssets.map(\.url))
        let finalURLs = orderedAssets.enumerated().map { index, asset in
            let number = options.startNumber + index
            let numberString = String(format: "%0\(max(1, options.minimumDigits))d", number)
            return directory.appendingPathComponent(
                "\(prefix)-\(numberString).\(asset.url.pathExtension)"
            )
        }

        for finalURL in finalURLs {
            if fileManager.fileExists(atPath: finalURL.path), !originalURLs.contains(finalURL) {
                throw FileBatchError.destinationExists(finalURL.lastPathComponent)
            }
        }

        let temporaryURLs = orderedAssets.map { asset in
            directory.appendingPathComponent(".image-viewer-rename-\(UUID().uuidString)")
        }

        var stagedCount = 0
        var finalizedCount = 0
        do {
            for (asset, temporaryURL) in zip(orderedAssets, temporaryURLs) {
                try fileManager.moveItem(at: asset.url, to: temporaryURL)
                stagedCount += 1
            }

            for (temporaryURL, finalURL) in zip(temporaryURLs, finalURLs) {
                try fileManager.moveItem(at: temporaryURL, to: finalURL)
                finalizedCount += 1
            }
        } catch {
            if finalizedCount > 0 {
                for index in stride(from: finalizedCount - 1, through: 0, by: -1) {
                    let finalURL = finalURLs[index]
                    if fileManager.fileExists(atPath: finalURL.path) {
                        try? fileManager.moveItem(at: finalURL, to: orderedAssets[index].url)
                    }
                }
            }
            if stagedCount > 0 {
                for index in stride(from: stagedCount - 1, through: 0, by: -1) {
                    let temporaryURL = temporaryURLs[index]
                    if fileManager.fileExists(atPath: temporaryURL.path) {
                        try? fileManager.moveItem(at: temporaryURL, to: orderedAssets[index].url)
                    }
                }
            }
            throw error
        }

        return finalURLs
    }
}

public enum FileBatchError: LocalizedError {
    case emptyPrefix
    case destinationExists(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPrefix:
            return "批量重命名前缀不能为空。"
        case let .destinationExists(filename):
            return "目标文件已存在：\(filename)"
        }
    }
}
