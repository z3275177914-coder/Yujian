import Foundation

public enum LocalToolName: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case openImage = "open_image"
    case getCurrentImage = "get_current_image"
    case getImageMetadata = "get_image_metadata"
    case listFolderImages = "list_folder_images"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openImage:
            return "打开图片"
        case .getCurrentImage:
            return "读取当前图片"
        case .getImageMetadata:
            return "读取图片元数据"
        case .listFolderImages:
            return "列出当前文件夹图片"
        }
    }
}

public enum LocalToolPermissionScope: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case readCurrentImage
    case listFolderImages
    case openImage

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .readCurrentImage:
            return "读取当前图片和元数据"
        case .listFolderImages:
            return "列出当前文件夹图片"
        case .openImage:
            return "请求打开图片"
        }
    }
}

public struct LocalToolPermissions: Codable, Equatable, Sendable {
    public var readCurrentImage: Bool
    public var listFolderImages: Bool
    public var openImage: Bool

    public init(
        readCurrentImage: Bool = false,
        listFolderImages: Bool = false,
        openImage: Bool = false
    ) {
        self.readCurrentImage = readCurrentImage
        self.listFolderImages = listFolderImages
        self.openImage = openImage
    }

    public static let disabled = LocalToolPermissions()

    public static func load() -> LocalToolPermissions {
        guard let data = UserDefaults.standard.data(forKey: "ImageViewer.localToolPermissions"),
              let permissions = try? JSONDecoder().decode(LocalToolPermissions.self, from: data) else {
            return .disabled
        }
        return permissions
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }
        UserDefaults.standard.set(data, forKey: "ImageViewer.localToolPermissions")
    }

    public mutating func set(_ allowed: Bool, for scope: LocalToolPermissionScope) {
        switch scope {
        case .readCurrentImage:
            readCurrentImage = allowed
        case .listFolderImages:
            listFolderImages = allowed
        case .openImage:
            openImage = allowed
        }
    }

    public func allows(_ tool: LocalToolName) -> Bool {
        switch tool {
        case .openImage:
            return openImage
        case .getCurrentImage, .getImageMetadata:
            return readCurrentImage
        case .listFolderImages:
            return listFolderImages
        }
    }

    public func allows(_ scope: LocalToolPermissionScope) -> Bool {
        switch scope {
        case .readCurrentImage:
            return readCurrentImage
        case .listFolderImages:
            return listFolderImages
        case .openImage:
            return openImage
        }
    }
}

public struct LocalToolRequest: Codable, Equatable, Sendable {
    public let tool: LocalToolName
    public let path: String?

    public init(tool: LocalToolName, path: String? = nil) {
        self.tool = tool
        self.path = path
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ImageViewerAppIdentity.acceptsURLScheme(components.scheme),
              components.host?.lowercased() == "tool" else {
            return nil
        }

        let rawTool = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .first
            .map(String.init)
        guard let rawTool,
              let tool = LocalToolName(rawValue: rawTool) else {
            return nil
        }

        let path = components.queryItems?
            .first(where: { $0.name == "path" })?
            .value
        self.init(tool: tool, path: path)
    }
}

public struct LocalToolImageSummary: Codable, Equatable, Sendable {
    public let path: String
    public let filename: String
    public let fileExtension: String
    public let dimensions: String
    public let fileSizeBytes: Int64
    public let modifiedAtTimestamp: Double?

    public init(asset: ImageAsset) {
        path = asset.url.path
        filename = asset.filename
        fileExtension = asset.fileExtension
        dimensions = asset.dimensionsLabel
        fileSizeBytes = asset.fileSize
        modifiedAtTimestamp = asset.modifiedAt?.timeIntervalSince1970
    }
}

public struct LocalToolMetadataField: Codable, Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct LocalToolResponse: Codable, Equatable, Sendable {
    public let tool: LocalToolName
    public let ok: Bool
    public let message: String
    public let image: LocalToolImageSummary?
    public let metadata: [LocalToolMetadataField]?
    public let images: [LocalToolImageSummary]?

    public init(
        tool: LocalToolName,
        ok: Bool,
        message: String,
        image: LocalToolImageSummary? = nil,
        metadata: [LocalToolMetadataField]? = nil,
        images: [LocalToolImageSummary]? = nil
    ) {
        self.tool = tool
        self.ok = ok
        self.message = message
        self.image = image
        self.metadata = metadata
        self.images = images
    }

    public static func success(
        for tool: LocalToolName,
        message: String,
        image: LocalToolImageSummary? = nil,
        metadata: [LocalToolMetadataField]? = nil,
        images: [LocalToolImageSummary]? = nil
    ) -> LocalToolResponse {
        LocalToolResponse(
            tool: tool,
            ok: true,
            message: message,
            image: image,
            metadata: metadata,
            images: images
        )
    }

    public static func failure(
        for tool: LocalToolName,
        message: String
    ) -> LocalToolResponse {
        LocalToolResponse(tool: tool, ok: false, message: message)
    }
}

public extension ImageMetadata {
    var localToolFields: [LocalToolMetadataField] {
        information.map { LocalToolMetadataField(label: $0.label, value: $0.value) }
            + exif.map { LocalToolMetadataField(label: "EXIF · \($0.label)", value: $0.value) }
            + advanced.map { LocalToolMetadataField(label: "高级 · \($0.label)", value: $0.value) }
    }
}
