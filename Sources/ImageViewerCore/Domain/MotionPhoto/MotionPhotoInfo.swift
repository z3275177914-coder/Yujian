import CoreMedia
import Foundation

/// The container format used by a still image's motion component.
public enum MotionPhotoFormat: String, Equatable, Hashable, Sendable {
    case android
    case samsung
    case appleLivePhoto
    case unknown
}

/// Indicates whether an Apple still/MOV relationship was verified by media
/// identifiers or came from the documented same-stem fallback.
public enum MotionPhotoPairingConfidence: String, Equatable, Hashable, Sendable {
    case verified
    case fallback
}

/// Describes where the video resource lives without opening or decoding it.
public enum MotionVideoSource: Equatable, Hashable, Sendable {
    case embedded(sourceURL: URL, offset: UInt64, length: UInt64)
    case external(URL)

    public var sourceURL: URL {
        switch self {
        case let .embedded(sourceURL, _, _):
            return sourceURL
        case let .external(url):
            return url
        }
    }
}

/// The single dynamic-photo model shared by detection and the existing viewer.
/// The still image remains owned by ImageAsset; this value only describes its
/// optional motion component.
public struct MotionPhotoInfo: Equatable, Hashable, @unchecked Sendable {
    public let format: MotionPhotoFormat
    public let videoSource: MotionVideoSource
    public let presentationTimestamp: CMTime?
    public let pairingConfidence: MotionPhotoPairingConfidence

    public init(
        format: MotionPhotoFormat,
        videoSource: MotionVideoSource,
        presentationTimestamp: CMTime? = nil,
        pairingConfidence: MotionPhotoPairingConfidence = .verified
    ) {
        self.format = format
        self.videoSource = videoSource
        self.presentationTimestamp = Self.validTimestamp(presentationTimestamp)
        self.pairingConfidence = pairingConfidence
    }

    private static func validTimestamp(_ timestamp: CMTime?) -> CMTime? {
        guard let timestamp,
              timestamp.isNumeric,
              timestamp.seconds.isFinite,
              timestamp.seconds >= 0 else {
            return nil
        }
        return timestamp
    }
}
