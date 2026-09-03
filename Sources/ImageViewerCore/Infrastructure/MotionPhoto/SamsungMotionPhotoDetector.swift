import CoreMedia
import Foundation

/// Detects Samsung's marker/trailer form without treating every JPEG with a
/// trailing payload as a motion photo. The marker is required before the
/// bounded trailer scan is attempted.
public struct SamsungMotionPhotoDetector: MotionPhotoDetecting, Sendable {
    private static let probeSize = 256 * 1024
    private static let trailerProbeSize = 512 * 1024

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

        let probe = read(
            from: handle,
            offset: 0,
            length: min(fileSize, UInt64(probeSize))
        )
        let trailer = read(
            from: handle,
            offset: fileSize - min(fileSize, UInt64(trailerProbeSize)),
            length: min(fileSize, UInt64(trailerProbeSize))
        )
        guard MotionPhotoXMPParser.hasSamsungMarker(in: probe)
            || MotionPhotoXMPParser.hasSamsungMarker(in: trailer) else {
            return nil
        }

        let explicit = MotionPhotoXMPParser.samsungMetadata(
            in: probe,
            fileSize: fileSize
        )
        let metadata = explicit ?? findTrailerMetadata(
            in: handle,
            fileSize: fileSize,
            timestampData: probe
        )
        guard let metadata,
              AndroidMotionPhotoDetector.hasMP4Signature(
                  in: handle,
                  offset: metadata.offset,
                  length: metadata.length
              ) else {
            return nil
        }

        return MotionPhotoInfo(
            format: .samsung,
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

    private static func findTrailerMetadata(
        in handle: FileHandle,
        fileSize: UInt64,
        timestampData: Data
    ) -> MotionPhotoEmbeddedMetadata? {
        guard let start = findJPEGEnd(in: handle, fileSize: fileSize),
              let videoOffset = findMP4Start(
                  in: handle,
                  fileSize: fileSize,
                  lowerBound: start
              ) else {
            return nil
        }

        return MotionPhotoEmbeddedMetadata(
            offset: videoOffset,
            length: fileSize - videoOffset,
            presentationTimestamp: MotionPhotoTimestampParser.value(in: timestampData)
        )
    }

    private static func findJPEGEnd(
        in handle: FileHandle,
        fileSize: UInt64
    ) -> UInt64? {
        let chunkSize: UInt64 = 1_048_576
        var offset: UInt64 = 0
        var previousByte: UInt8?
        while offset < fileSize {
            guard !Task.isCancelled else {
                return nil
            }
            let length = Int(min(chunkSize, fileSize - offset))
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: length),
                  !data.isEmpty else {
                return nil
            }
            for (index, byte) in data.enumerated() {
                if previousByte == 0xFF, byte == 0xD9 {
                    return offset + UInt64(index + 1)
                }
                previousByte = byte
            }
            offset += UInt64(data.count)
        }
        return nil
    }

    private static func findMP4Start(
        in handle: FileHandle,
        fileSize: UInt64,
        lowerBound: UInt64
    ) -> UInt64? {
        let chunkSize: UInt64 = 1_048_576
        let ftyp = Data("ftyp".utf8)
        var offset = lowerBound
        while offset < fileSize {
            guard !Task.isCancelled else {
                return nil
            }
            let length = Int(min(chunkSize, fileSize - offset))
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: length),
                  !data.isEmpty else {
                return nil
            }
            if let range = data.range(of: ftyp), range.lowerBound >= 4 {
                let candidate = offset + UInt64(range.lowerBound - 4)
                if candidate >= lowerBound {
                    return candidate
                }
            }
            if data.count < length {
                return nil
            }
            offset += UInt64(max(1, data.count - 3))
        }
        return nil
    }

    private static func read(
        from handle: FileHandle,
        offset: UInt64,
        length: UInt64
    ) -> Data {
        guard length > 0,
              (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(length)) else {
            return Data()
        }
        return data
    }
}

private enum MotionPhotoTimestampParser {
    static func value(in data: Data) -> Int64? {
        let text = String(decoding: data, as: UTF8.self)
        let names = [
            "MotionPhotoPresentationTimestampUs",
            "MicroVideoPresentationTimestampUs",
            "PresentationTimestampUs"
        ]
        for name in names {
            guard let range = text.range(of: name),
                  let equals = text[range.upperBound...].firstIndex(of: "=") else {
                continue
            }
            var valueStart = text.index(after: equals)
            while valueStart < text.endIndex,
                  text[valueStart].isWhitespace || text[valueStart] == "\""
                    || text[valueStart] == "'" {
                valueStart = text.index(after: valueStart)
            }
            let value = text[valueStart...].prefix {
                $0.isNumber || $0 == "-"
            }
            if let number = Int64(value), number >= 0 {
                return number
            }
        }
        return nil
    }
}
