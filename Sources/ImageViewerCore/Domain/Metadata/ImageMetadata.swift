import Foundation

public struct MetadataField: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.id = label
        self.label = label
        self.value = value
    }
}

public struct ImageMetadata: Hashable, Sendable {
    public let information: [MetadataField]
    public let exif: [MetadataField]
    public let advanced: [MetadataField]

    public init(
        information: [MetadataField] = [],
        exif: [MetadataField] = [],
        advanced: [MetadataField] = []
    ) {
        self.information = information
        self.exif = exif
        self.advanced = advanced
    }
}
