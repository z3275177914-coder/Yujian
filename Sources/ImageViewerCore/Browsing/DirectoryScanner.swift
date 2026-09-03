import Foundation

public struct DirectoryScanBatch: Sendable {
    public let assets: [ImageAsset]
    public let isComplete: Bool

    public init(assets: [ImageAsset], isComplete: Bool = false) {
        self.assets = assets
        self.isComplete = isComplete
    }
}

public actor DirectoryScanner {
    public init() {}

    public func scan(directoryURL: URL) -> [ImageAsset] {
        let signpostID = PerformanceLog.begin("DirectoryScan")
        defer {
            PerformanceLog.end("DirectoryScan", signpostID: signpostID)
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey
        ]

        return Self.imageURLs(
            in: directoryURL,
            resourceKeys: keys
        ).map(ImageAsset.init(url:))
    }

    /// Produces small asset batches so the UI can start showing a directory
    /// before all entries have had their metadata inspected.
    public func scanBatches(
        directoryURL: URL,
        batchSize: Int = 128
    ) -> AsyncStream<DirectoryScanBatch> {
        let safeBatchSize = max(1, batchSize)
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                let urls = Self.imageURLs(in: directoryURL)
                var batch: [ImageAsset] = []
                batch.reserveCapacity(safeBatchSize)

                for url in urls {
                    guard !Task.isCancelled else {
                        break
                    }
                    batch.append(ImageAsset(url: url))
                    if batch.count >= safeBatchSize {
                        continuation.yield(DirectoryScanBatch(assets: batch))
                        batch.removeAll(keepingCapacity: true)
                        await Task.yield()
                    }
                }

                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                if !batch.isEmpty {
                    continuation.yield(DirectoryScanBatch(assets: batch))
                }
                continuation.yield(DirectoryScanBatch(assets: [], isComplete: true))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func imageURLs(
        in directoryURL: URL,
        resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey
        ]
    ) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey
                ]) else {
                    return false
                }
                return values.isDirectory != true
                    && values.isRegularFile == true
                    && ImageAsset.isSupportedImage(url)
            }
            .sorted(by: naturalAscending)
    }

    private static func naturalAscending(_ lhs: URL, _ rhs: URL) -> Bool {
        let comparison = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        return lhs.path < rhs.path
    }
}
