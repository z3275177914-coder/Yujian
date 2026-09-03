import CoreGraphics
import Dispatch
import Foundation

public enum ImageCachePriority: String, Equatable, Sendable {
    case current
    case prefetch
}

public enum ImagePrefetchDirection: String, Equatable, Sendable {
    case forward
    case backward
}

public struct ImageCacheKey: Hashable, Sendable {
    public let path: String
    public let fileSize: Int64
    public let modificationTimeNanoseconds: Int64
    public let fileNumber: Int64
    public let maxPixelSize: Int?

    public init(
        path: String,
        fileSize: Int64,
        modificationTimeNanoseconds: Int64,
        fileNumber: Int64,
        maxPixelSize: Int?
    ) {
        self.path = path
        self.fileSize = fileSize
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.fileNumber = fileNumber
        self.maxPixelSize = maxPixelSize
    }
}

public struct ImageCacheStats: Equatable, Sendable {
    public let entryCount: Int
    public let currentCost: Int
    public let byteBudget: Int
    public let hitCount: Int
    public let missCount: Int
    public let coalescedRequestCount: Int
    public let evictionCount: Int
    public let cancellationCount: Int
    public let memoryPressureTrimCount: Int
    public let inFlightCount: Int
    public let lastPrefetchDirection: ImagePrefetchDirection?

    public init(
        entryCount: Int,
        currentCost: Int,
        byteBudget: Int,
        hitCount: Int,
        missCount: Int,
        coalescedRequestCount: Int,
        evictionCount: Int,
        cancellationCount: Int,
        memoryPressureTrimCount: Int,
        inFlightCount: Int,
        lastPrefetchDirection: ImagePrefetchDirection?
    ) {
        self.entryCount = entryCount
        self.currentCost = currentCost
        self.byteBudget = byteBudget
        self.hitCount = hitCount
        self.missCount = missCount
        self.coalescedRequestCount = coalescedRequestCount
        self.evictionCount = evictionCount
        self.cancellationCount = cancellationCount
        self.memoryPressureTrimCount = memoryPressureTrimCount
        self.inFlightCount = inFlightCount
        self.lastPrefetchDirection = lastPrefetchDirection
    }
}

/// Byte-budgeted decoded image cache. It owns disk fingerprints, in-flight
/// decode coalescing and prefetch cancellation off the main actor.
public actor ImageDecodeCache {
    public static let shared = ImageDecodeCache()

    private struct InFlightRequest {
        let id: UInt64
        let generation: UInt64
        let task: Task<CGImage?, Never>
    }

    private struct Entry {
        let image: CGImage
        let cost: Int
        var lastAccess: UInt64
    }

    private let byteBudget: Int
    private let decoder: @Sendable (URL, Int?) -> CGImage?
    private var entries: [ImageCacheKey: Entry] = [:]
    private var inFlight: [ImageCacheKey: InFlightRequest] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var accessCounter: UInt64 = 0
    private var nextRequestID: UInt64 = 0
    private var generation: UInt64 = 0
    private var totalCost = 0
    private var hitCount = 0
    private var missCount = 0
    private var coalescedRequestCount = 0
    private var evictionCount = 0
    private var cancellationCount = 0
    private var memoryPressureTrimCount = 0
    private var lastPrefetchDirection: ImagePrefetchDirection?
    private let memoryPressureSource: DispatchSourceMemoryPressure

    public init(
        byteBudget: Int = 256 * 1024 * 1024,
        decoder: @escaping @Sendable (URL, Int?) -> CGImage? = { url, maxPixelSize in
            ImageDecoder.decodeCGImage(url: url, maxPixelSize: maxPixelSize)
        }
    ) {
        self.byteBudget = max(1, byteBudget)
        self.decoder = decoder
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.trimForMemoryPressure()
            }
        }
        source.resume()
    }

    public func key(
        for url: URL,
        maxPixelSize: Int?
    ) -> ImageCacheKey {
        makeKey(url: url, maxPixelSize: maxPixelSize)
    }

    /// Looks up a decoded image without starting a disk decode. This keeps
    /// the thumbnail path free to check the persistent cache first.
    public func cachedImage(
        for url: URL,
        maxPixelSize: Int?
    ) -> CGImage? {
        let key = makeKey(url: url, maxPixelSize: maxPixelSize)
        guard var entry = entries[key] else {
            return nil
        }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        entries[key] = entry
        hitCount += 1
        return entry.image
    }

    public func store(
        _ image: CGImage,
        for url: URL,
        maxPixelSize: Int?
    ) {
        insert(
            image,
            for: makeKey(url: url, maxPixelSize: maxPixelSize)
        )
    }

    public func image(
        for url: URL,
        maxPixelSize: Int?,
        priority: ImageCachePriority = .current
    ) async -> CGImage? {
        let key = makeKey(url: url, maxPixelSize: maxPixelSize)
        if var entry = entries[key] {
            accessCounter &+= 1
            entry.lastAccess = accessCounter
            entries[key] = entry
            hitCount += 1
            return entry.image
        }

        let request: InFlightRequest
        if let existing = inFlight[key] {
            coalescedRequestCount += 1
            request = existing
        } else {
            missCount += 1
            let taskPriority: TaskPriority = priority == .current ? .userInitiated : .utility
            let imageDecoder = decoder
            let task = Task.detached(priority: taskPriority) {
                imageDecoder(url, maxPixelSize)
            }
            nextRequestID &+= 1
            request = InFlightRequest(
                id: nextRequestID,
                generation: generation,
                task: task
            )
            inFlight[key] = request
        }

        let decoded = await request.task.value
        if inFlight[key]?.id == request.id {
            inFlight.removeValue(forKey: key)
        }
        // A clear can happen while ImageIO is still decoding. Prevent an old
        // result from silently repopulating a cache the user just discarded.
        if let decoded, request.generation == generation {
            insert(decoded, for: key)
        }
        guard !Task.isCancelled else {
            cancellationCount += 1
            return nil
        }
        return decoded
    }

    public func prefetch(
        urls: [URL],
        maxPixelSize: Int,
        direction: ImagePrefetchDirection
    ) {
        prefetchTask?.cancel()
        lastPrefetchDirection = direction
        let orderedURLs = urls
        prefetchTask = Task { [weak self] in
            for url in orderedURLs {
                guard !Task.isCancelled else {
                    return
                }
                _ = await self?.image(
                    for: url,
                    maxPixelSize: maxPixelSize,
                    priority: .prefetch
                )
            }
        }
    }

    public func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    public func removeAll() {
        generation &+= 1
        entries.removeAll(keepingCapacity: true)
        totalCost = 0
        for task in inFlight.values {
            task.task.cancel()
        }
        inFlight.removeAll(keepingCapacity: true)
        cancelPrefetch()
    }

    public func trimForMemoryPressure() {
        let target = byteBudget / 2
        while totalCost > target, let key = leastRecentlyUsedKey() {
            evict(key)
        }
        memoryPressureTrimCount += 1
    }

    public func stats() -> ImageCacheStats {
        ImageCacheStats(
            entryCount: entries.count,
            currentCost: totalCost,
            byteBudget: byteBudget,
            hitCount: hitCount,
            missCount: missCount,
            coalescedRequestCount: coalescedRequestCount,
            evictionCount: evictionCount,
            cancellationCount: cancellationCount,
            memoryPressureTrimCount: memoryPressureTrimCount,
            inFlightCount: inFlight.count,
            lastPrefetchDirection: lastPrefetchDirection
        )
    }

    private func insert(_ image: CGImage, for key: ImageCacheKey) {
        let cost = imageCost(image)
        guard cost <= byteBudget else {
            return
        }

        if let previous = entries.removeValue(forKey: key) {
            totalCost -= previous.cost
        }
        while totalCost + cost > byteBudget, let keyToEvict = leastRecentlyUsedKey() {
            evict(keyToEvict)
        }

        accessCounter &+= 1
        entries[key] = Entry(
            image: image,
            cost: cost,
            lastAccess: accessCounter
        )
        totalCost += cost
    }

    private func evict(_ key: ImageCacheKey) {
        guard let entry = entries.removeValue(forKey: key) else {
            return
        }
        totalCost -= entry.cost
        evictionCount += 1
    }

    private func leastRecentlyUsedKey() -> ImageCacheKey? {
        entries.min { lhs, rhs in
            lhs.value.lastAccess < rhs.value.lastAccess
        }?.key
    }

    private func makeKey(url: URL, maxPixelSize: Int?) -> ImageCacheKey {
        let standardizedURL = url.standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: standardizedURL.path
        )
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modificationDate = attributes?[.modificationDate] as? Date
        let modificationTimeNanoseconds: Int64
        if let modificationDate {
            modificationTimeNanoseconds = Int64(
                (modificationDate.timeIntervalSince1970 * 1_000_000_000).rounded()
            )
        } else {
            modificationTimeNanoseconds = -1
        }
        let fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.int64Value ?? -1
        return ImageCacheKey(
            path: standardizedURL.path,
            fileSize: fileSize,
            modificationTimeNanoseconds: modificationTimeNanoseconds,
            fileNumber: fileNumber,
            maxPixelSize: maxPixelSize.map { max(1, $0) }
        )
    }

    private func imageCost(_ image: CGImage) -> Int {
        let pixels = Int64(image.width) * Int64(image.height)
        let bytes = min(Int64(Int.max), max(1, pixels) * 4)
        return Int(bytes)
    }
}
