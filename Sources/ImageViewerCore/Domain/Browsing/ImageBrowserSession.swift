import Foundation

public struct ImageBrowserSession: Sendable {
    public let directoryURL: URL
    public var assets: [ImageAsset]
    public var currentIndex: Int
    public var sortOrder: SortOrder
    public var recursive: Bool

    public enum SortOrder: String, Sendable {
        case filename
    }

    public init(
        directoryURL: URL,
        assets: [ImageAsset] = [],
        currentIndex: Int = 0,
        sortOrder: SortOrder = .filename,
        recursive: Bool = false
    ) {
        self.directoryURL = directoryURL
        self.assets = assets
        self.currentIndex = currentIndex
        self.sortOrder = sortOrder
        self.recursive = recursive
    }

    public var currentAsset: ImageAsset? {
        guard assets.indices.contains(currentIndex) else {
            return nil
        }
        return assets[currentIndex]
    }
}
