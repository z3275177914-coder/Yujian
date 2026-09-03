import CoreMedia
import Foundation

/// Detects the current Android Motion Photo XMP/container representation.
public struct AndroidMotionPhotoDetector: MotionPhotoDetecting, Sendable {
    public init() {}

    public func detect(url: URL) async throws -> MotionPhotoInfo? {
        try Task.checkCancellation()
        let normalizedURL = url.standardizedFileURL
        return try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return Self.detectSynchronously(url: normalizedURL)
        }.value
    }

    private static func detectSynchronously(url: URL) -> MotionPhotoInfo? {
        guard isCandidateStill(url),
              let values = try? url.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .fileSizeKey
              ]),
              values.isRegularFile == true else {
            return nil
        }

        let fileSize = UInt64(max(0, values.fileSize ?? 0))
        guard fileSize > 0,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        let probeSize = Int(min(fileSize, 256 * 1024))
        guard let xmpData = try? handle.read(upToCount: probeSize),
              let metadata = MotionPhotoXMPParser.androidMetadata(
                  in: xmpData,
                  fileSize: fileSize
              ),
              hasMP4Signature(
                  in: handle,
                  offset: metadata.offset,
                  length: metadata.length
              ) else {
            return nil
        }

        return MotionPhotoInfo(
            format: .android,
            videoSource: .embedded(
                sourceURL: url,
                offset: metadata.offset,
                length: metadata.length
            ),
            presentationTimestamp: metadata.presentationTimestamp.map {
                CMTime(value: $0, timescale: 1_000_000)
            }
        )
    }

    static func hasMP4Signature(
        in handle: FileHandle,
        offset: UInt64,
        length: UInt64
    ) -> Bool {
        guard MotionPhotoXMPParser.isValidRange(
                  offset: offset,
                  length: length,
                  fileSize: UInt64.max
              ),
              length >= 8,
              (try? handle.seek(toOffset: offset)) != nil,
              let header = try? handle.read(upToCount: Int(min(length, 64))),
              let ftyp = "ftyp".data(using: .ascii),
              let ftypRange = header.range(of: ftyp) else {
            return false
        }
        return ftypRange.lowerBound <= 32
    }

    static func isCandidateStill(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe", "jfif", "heic", "heif":
            return true
        default:
            return false
        }
    }
}
