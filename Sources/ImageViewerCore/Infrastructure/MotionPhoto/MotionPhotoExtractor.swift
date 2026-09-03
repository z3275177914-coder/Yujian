import Foundation

/// Streams one validated embedded range into the Motion Photo cache. The
/// source JPEG is never loaded as a whole and extraction is cancellable.
public enum MotionPhotoExtractor {
    public static func extractEmbeddedVideo(
        from sourceURL: URL,
        offset: UInt64,
        length: UInt64,
        cache: MotionPhotoCache = .shared
    ) async throws -> URL {
        try Task.checkCancellation()
        if let cachedURL = try await cache.cachedURL(
            for: sourceURL,
            offset: offset,
            length: length
        ) {
            return cachedURL
        }

        let temporaryURL = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try extractSynchronously(
                from: sourceURL,
                offset: offset,
                length: length
            )
        }.value

        do {
            return try await cache.store(
                temporaryURL: temporaryURL,
                for: sourceURL,
                offset: offset,
                length: length
            )
        } catch {
            // Cache failure is non-fatal for playback. The controller owns and
            // removes this temporary fallback URL when it stops.
            return temporaryURL
        }
    }

    public static func isValidRange(
        fileSize: UInt64,
        offset: UInt64,
        length: UInt64
    ) -> Bool {
        MotionPhotoXMPParser.isValidRange(
            offset: offset,
            length: length,
            fileSize: fileSize
        )
    }

    private static func extractSynchronously(
        from sourceURL: URL,
        offset: UInt64,
        length: UInt64
    ) throws -> URL {
        let values = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey
        ])
        let fileSize = UInt64(max(0, values.fileSize ?? 0))
        guard values.isRegularFile == true,
              isValidRange(fileSize: fileSize, offset: offset, length: length) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageViewerMotionPhoto-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let input = try FileHandle(forReadingFrom: sourceURL)
            let output = try FileHandle(forWritingTo: outputURL)
            defer {
                try? input.close()
                try? output.close()
            }

            try input.seek(toOffset: offset)
            var remaining = length
            while remaining > 0 {
                try Task.checkCancellation()
                let chunkSize = Int(min(1_048_576, remaining))
                guard let chunk = try input.read(upToCount: chunkSize),
                      !chunk.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try output.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}
