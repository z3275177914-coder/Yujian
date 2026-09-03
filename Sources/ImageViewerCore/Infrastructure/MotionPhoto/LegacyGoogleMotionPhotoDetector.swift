import CoreMedia
import Foundation

/// Detects the legacy Google Camera MicroVideo representation separately from
/// the current Android Motion Photo container metadata.
public struct LegacyGoogleMotionPhotoDetector: MotionPhotoDetecting, Sendable {
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
        guard AndroidMotionPhotoDetector.isCandidateStill(url),
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
              let metadata = MotionPhotoXMPParser.legacyGoogleMetadata(
                  in: xmpData,
                  fileSize: fileSize
              ),
              AndroidMotionPhotoDetector.hasMP4Signature(
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
}
