import CryptoKit
import Foundation

/// Persistent, bounded cache for extracted embedded Motion Photo movies.
public actor MotionPhotoCache {
    public static let shared = MotionPhotoCache()

    public let directoryURL: URL
    public let maxByteCount: Int64

    public init(
        directoryURL: URL? = nil,
        maxByteCount: Int64 = 512 * 1024 * 1024
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL
        self.maxByteCount = max(1, maxByteCount)
    }

    public func cachedURL(
        for sourceURL: URL,
        offset: UInt64,
        length: UInt64
    ) throws -> URL? {
        let destinationURL = try destinationURL(
            for: sourceURL,
            offset: offset,
            length: length
        )
        guard let values = try? destinationURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey
        ]),
        values.isRegularFile == true,
        UInt64(max(0, values.fileSize ?? 0)) == length else {
            return nil
        }
        touch(destinationURL)
        return destinationURL
    }

    public func store(
        temporaryURL: URL,
        for sourceURL: URL,
        offset: UInt64,
        length: UInt64
    ) throws -> URL {
        let destination = try destinationURL(
            for: sourceURL,
            offset: offset,
            length: length
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            let existingValues = try? destination.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey
            ])
            if existingValues?.isRegularFile == true,
               UInt64(max(0, existingValues?.fileSize ?? 0)) == length {
                try? FileManager.default.removeItem(at: temporaryURL)
                touch(destination)
                return destination
            }
            try FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        touch(destination)
        cleanupIfNeeded()
        return destination
    }

    public func cleanup() {
        cleanupIfNeeded()
    }

    public static var defaultDirectoryURL: URL {
        let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return cachesURL
            .appendingPathComponent(ImageViewerAppIdentity.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("MotionPhoto", isDirectory: true)
    }

    public static func isManagedURL(_ url: URL) -> Bool {
        let managedPath = defaultDirectoryURL.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath == managedPath
            || candidatePath.hasPrefix(managedPath + "/")
    }

    private func destinationURL(
        for sourceURL: URL,
        offset: UInt64,
        length: UInt64
    ) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value
        let modificationDate = attributes[.modificationDate] as? Date
        guard let fileSize,
              fileSize >= 0,
              MotionPhotoXMPParser.isValidRange(
                  offset: offset,
                  length: length,
                  fileSize: UInt64(fileSize)
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let sourceSignature = [
            sourceURL.standardizedFileURL.path,
            String(fileSize),
            String(modificationDate?.timeIntervalSince1970 ?? 0),
            String(offset),
            String(length)
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(sourceSignature.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directoryURL.appendingPathComponent(digest).appendingPathExtension("mp4")
    }

    private func cleanupIfNeeded() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .contentAccessDateKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        )) ?? []
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard url.pathExtension.lowercased() == "mp4",
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey,
                      .fileSizeKey,
                      .contentAccessDateKey,
                      .contentModificationDateKey
                  ]),
                  values.isRegularFile == true else {
                return nil
            }
            let size = Int64(max(0, values.fileSize ?? 0))
            let date = values.contentAccessDate
                ?? values.contentModificationDate
                ?? .distantPast
            return (url, size, date)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        entries.sort { $0.2 < $1.2 }
        while total > maxByteCount, let entry = entries.first {
            entries.removeFirst()
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }

    private func touch(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.contentAccessDate = Date()
        try? url.setResourceValues(values)
    }
}
