import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct DiskThumbnailKey: Hashable, Sendable {
    public let path: String
    public let fileSize: Int64
    public let modificationTimeNanoseconds: Int64
    public let fileNumber: Int64
    public let maxPixelSize: Int

    public init(url: URL, maxPixelSize: Int) {
        let standardizedURL = url.standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: standardizedURL.path
        )
        let modificationDate = attributes?[.modificationDate] as? Date
        self.path = standardizedURL.path
        self.fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        self.modificationTimeNanoseconds = Self.nanoseconds(
            from: modificationDate
        )
        self.fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.int64Value ?? -1
        self.maxPixelSize = max(1, maxPixelSize)
    }

    public var filename: String {
        let material = "\(path)|\(fileSize)|\(modificationTimeNanoseconds)|\(fileNumber)|\(maxPixelSize)"
        return "v1-\(String(Self.stableHash(material), radix: 16)).png"
    }

    private static func nanoseconds(from date: Date?) -> Int64 {
        guard let date else {
            return -1
        }
        return Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

public struct DiskThumbnailCacheStats: Equatable, Sendable {
    public let entryCount: Int
    public let currentBytes: Int64
    public let byteBudget: Int64
    public let hitCount: Int
    public let missCount: Int
    public let writeCount: Int
    public let corruptedEntryCount: Int
    public let expiredEntryCount: Int
    public let evictionCount: Int

    public init(
        entryCount: Int,
        currentBytes: Int64,
        byteBudget: Int64,
        hitCount: Int,
        missCount: Int,
        writeCount: Int,
        corruptedEntryCount: Int,
        expiredEntryCount: Int,
        evictionCount: Int
    ) {
        self.entryCount = entryCount
        self.currentBytes = currentBytes
        self.byteBudget = byteBudget
        self.hitCount = hitCount
        self.missCount = missCount
        self.writeCount = writeCount
        self.corruptedEntryCount = corruptedEntryCount
        self.expiredEntryCount = expiredEntryCount
        self.evictionCount = evictionCount
    }
}

/// Persistent PNG thumbnails keyed by source identity and target size.
/// Corrupt, expired, or over-budget files are removed without affecting the
/// in-memory decoded-image cache.
public actor DiskThumbnailCache {
    public static let shared = DiskThumbnailCache()

    private let rootURL: URL
    private let byteBudget: Int64
    private let maxAge: TimeInterval
    private var hitCount = 0
    private var missCount = 0
    private var writeCount = 0
    private var corruptedEntryCount = 0
    private var expiredEntryCount = 0
    private var evictionCount = 0

    public init(
        rootURL: URL? = nil,
        byteBudget: Int64 = 512 * 1024 * 1024,
        maxAge: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.rootURL = rootURL ?? Self.defaultRootURL()
        self.byteBudget = max(1, byteBudget)
        self.maxAge = maxAge
        try? FileManager.default.createDirectory(
            at: self.rootURL,
            withIntermediateDirectories: true
        )
    }

    public func key(for url: URL, maxPixelSize: Int) -> DiskThumbnailKey {
        DiskThumbnailKey(url: url, maxPixelSize: maxPixelSize)
    }

    public func cacheFileURL(for key: DiskThumbnailKey) -> URL {
        rootURL.appendingPathComponent(key.filename, isDirectory: false)
    }

    public func image(for url: URL, maxPixelSize: Int) async -> CGImage? {
        let key = DiskThumbnailKey(url: url, maxPixelSize: maxPixelSize)
        let fileURL = cacheFileURL(for: key)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if isExpired(fileURL) {
                expiredEntryCount += 1
                removeFile(fileURL)
            } else if let cached = await Self.readImage(from: fileURL) {
                hitCount += 1
                touch(fileURL)
                return cached
            } else {
                corruptedEntryCount += 1
                removeFile(fileURL)
            }
        }

        missCount += 1
        let decoded = await Task.detached(priority: .utility) {
            ImageDecoder.decodeCGImage(
                url: url,
                maxPixelSize: max(1, maxPixelSize)
            )
        }.value
        if let decoded {
            store(decoded, for: key)
        }
        return decoded
    }

    public func store(
        _ image: CGImage,
        for url: URL,
        maxPixelSize: Int
    ) {
        store(
            image,
            for: DiskThumbnailKey(url: url, maxPixelSize: maxPixelSize)
        )
    }

    public func removeAll() {
        let files = cacheFiles().map(\.url)
        for file in files {
            removeFile(file)
        }
        hitCount = 0
        missCount = 0
        writeCount = 0
        corruptedEntryCount = 0
        expiredEntryCount = 0
        evictionCount = 0
    }

    public func stats() -> DiskThumbnailCacheStats {
        let files = cacheFiles()
        return DiskThumbnailCacheStats(
            entryCount: files.count,
            currentBytes: files.reduce(0) { $0 + $1.byteCount },
            byteBudget: byteBudget,
            hitCount: hitCount,
            missCount: missCount,
            writeCount: writeCount,
            corruptedEntryCount: corruptedEntryCount,
            expiredEntryCount: expiredEntryCount,
            evictionCount: evictionCount
        )
    }

    private func store(_ image: CGImage, for key: DiskThumbnailKey) {
        let destinationURL = cacheFileURL(for: key)
        let temporaryURL = rootURL.appendingPathComponent(
            ".\(key.filename).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { removeFile(temporaryURL) }

        guard let destination = CGImageDestinationCreateWithURL(
            temporaryURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL
                )
            } else {
                try FileManager.default.moveItem(
                    at: temporaryURL,
                    to: destinationURL
                )
            }
            writeCount += 1
            enforceBudget()
        } catch {
            return
        }
    }

    private func enforceBudget() {
        var files = cacheFiles()
        var total = files.reduce(0) { $0 + $1.byteCount }
        while total > byteBudget,
              let oldestIndex = files.indices.min(by: {
                  files[$0].modificationDate < files[$1].modificationDate
              }) {
            let oldest = files.remove(at: oldestIndex)
            total -= oldest.byteCount
            removeFile(oldest.url)
            evictionCount += 1
        }
    }

    private func cacheFiles() -> [CacheFile] {
        let keys: [URLResourceKey] = [
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "png",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate else {
                return nil
            }
            return CacheFile(
                url: url,
                byteCount: Int64(max(0, size)),
                modificationDate: modified
            )
        }
    }

    private func isExpired(_ url: URL) -> Bool {
        guard maxAge > 0,
              maxAge.isFinite,
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate else {
            return false
        }
        return Date().timeIntervalSince(modified) > maxAge
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    private func removeFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func readImage(from url: URL) async -> CGImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }.value
    }

    private static func defaultRootURL() -> URL {
        let cachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return cachesURL
            .appendingPathComponent("ImageViewer", isDirectory: true)
            .appendingPathComponent("Thumbnails-v1", isDirectory: true)
    }

    private struct CacheFile {
        let url: URL
        let byteCount: Int64
        let modificationDate: Date
    }
}
