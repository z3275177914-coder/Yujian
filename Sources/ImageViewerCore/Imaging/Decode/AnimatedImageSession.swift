import CoreGraphics
import Foundation
import ImageIO

public struct AnimatedImageSessionStats: Equatable, Sendable {
    public let frameCount: Int
    public let cachedFrameCount: Int
    public let currentCost: Int
    public let byteBudget: Int
    public let isClosed: Bool

    public init(
        frameCount: Int,
        cachedFrameCount: Int,
        currentCost: Int,
        byteBudget: Int,
        isClosed: Bool
    ) {
        self.frameCount = frameCount
        self.cachedFrameCount = cachedFrameCount
        self.currentCost = currentCost
        self.byteBudget = byteBudget
        self.isClosed = isClosed
    }
}

/// Keeps the image source alive while decoding only the current frame and a
/// small neighborhood. The serial queue is also the sole queue touching the
/// CGImageSource, while the lock protects the bounded frame cache and close
/// state exposed to the UI actor.
public final class AnimatedImageSession: @unchecked Sendable {
    public let sourceURL: URL
    public let frameCount: Int
    public let maxPixelSize: Int
    public let windowSize: Int
    public let byteBudget: Int

    private struct CachedFrame {
        let image: CGImage
        let cost: Int
        var lastAccess: UInt64
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var source: CGImageSource?
    private let durations: [TimeInterval]
    private var frames: [Int: CachedFrame] = [:]
    private var queuedPrefetchIndices: Set<Int> = []
    private var prefetchGeneration: UInt64 = 0
    private var accessCounter: UInt64 = 0
    private var totalCost = 0
    private var closed = false

    private init(
        sourceURL: URL,
        source: CGImageSource,
        frameCount: Int,
        durations: [TimeInterval],
        maxPixelSize: Int,
        windowSize: Int,
        byteBudget: Int
    ) {
        self.sourceURL = sourceURL
        self.source = source
        self.frameCount = frameCount
        self.durations = durations
        self.maxPixelSize = max(1, maxPixelSize)
        self.windowSize = max(0, windowSize)
        self.byteBudget = max(1, byteBudget)
        self.queue = DispatchQueue(
            label: "com.imageviewer.animated-image-session",
            qos: .userInitiated
        )
    }

    /// Opens only the source and frame metadata. No frame bitmap is decoded
    /// until `image(at:)` is requested.
    public static func open(
        url: URL,
        maxPixelSize: Int = 1_024,
        windowSize: Int = 2,
        byteBudget: Int = 64 * 1024 * 1024
    ) async -> AnimatedImageSession? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            let frameCount = CGImageSourceGetCount(source)
            guard frameCount > 1 else {
                return nil
            }

            let durations = (0..<frameCount).map {
                Self.frameDuration(source: source, index: $0)
            }
            return AnimatedImageSession(
                sourceURL: url,
                source: source,
                frameCount: frameCount,
                durations: durations,
                maxPixelSize: maxPixelSize,
                windowSize: windowSize,
                byteBudget: byteBudget
            )
        }.value
    }

    public func image(at index: Int) async -> CGImage? {
        guard frameCount > 0 else {
            return nil
        }
        let normalizedIndex = ((index % frameCount) + frameCount) % frameCount
        guard !Task.isCancelled, !isClosed else {
            return nil
        }

        if let cached = cachedImage(at: normalizedIndex) {
            // A cache hit still advances playback. Rebuild the tiny
            // neighborhood around the hit so the next frame is ready before
            // its deadline instead of forcing every other frame through
            // ImageIO synchronously.
            cancelQueuedPrefetch()
            schedulePrefetch(around: normalizedIndex)
            return cached
        }
        // A current-frame request must not wait behind a stale prefetch burst.
        // Work already inside ImageIO cannot be interrupted, but queued work
        // will observe the new generation and exit before decoding.
        cancelQueuedPrefetch()

        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                guard !self.isClosed else {
                    continuation.resume(returning: nil)
                    return
                }

                let image = self.decodeFrame(at: normalizedIndex)
                continuation.resume(returning: image)
                if image != nil {
                    self.schedulePrefetch(around: normalizedIndex)
                }
            }
        }
    }

    public func duration(at index: Int) -> TimeInterval {
        guard !durations.isEmpty else {
            return 0.1
        }
        let normalizedIndex = ((index % durations.count) + durations.count) % durations.count
        return max(0.02, durations[normalizedIndex])
    }

    public func stats() -> AnimatedImageSessionStats {
        lock.lock()
        defer { lock.unlock() }
        return AnimatedImageSessionStats(
            frameCount: frameCount,
            cachedFrameCount: frames.count,
            currentCost: totalCost,
            byteBudget: byteBudget,
            isClosed: closed
        )
    }

    /// Invalidates queued work and releases cached frames/source on the
    /// session queue. A decode already inside ImageIO may finish, but its
    /// result is never republished after the session is closed.
    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        frames.removeAll(keepingCapacity: false)
        queuedPrefetchIndices.removeAll(keepingCapacity: false)
        prefetchGeneration &+= 1
        totalCost = 0
        lock.unlock()

        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.lock.lock()
            self.source = nil
            self.frames.removeAll(keepingCapacity: false)
            self.totalCost = 0
            self.lock.unlock()
        }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func decodeFrame(at index: Int) -> CGImage? {
        lock.lock()
        if var cached = frames[index] {
            accessCounter &+= 1
            cached.lastAccess = accessCounter
            frames[index] = cached
            lock.unlock()
            return cached.image
        }
        let source = source
        let closed = self.closed
        lock.unlock()

        guard !closed, let source else {
            return nil
        }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Materialize the frame while the session queue is decoding it so
            // the AppKit layer swap never pays ImageIO's lazy decode cost.
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            index,
            options
        ) else {
            return nil
        }

        let cost = max(1, image.width * image.height * 4)
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !self.closed else {
            return nil
        }
        insert(image, at: index, cost: cost)
        return image
    }

    private func schedulePrefetch(around index: Int) {
        guard windowSize > 0 else {
            return
        }
        var jobs: [(index: Int, generation: UInt64)] = []
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        let generation = prefetchGeneration
        for offset in 1...windowSize {
            let forward = (index + offset) % frameCount
            let backward = (index - offset + frameCount) % frameCount
            for candidate in [forward, backward] where candidate != index {
                guard frames[candidate] == nil,
                      !queuedPrefetchIndices.contains(candidate) else {
                    continue
                }
                queuedPrefetchIndices.insert(candidate)
                jobs.append((candidate, generation))
            }
        }
        lock.unlock()

        for job in jobs {
            queue.async { [weak self] in
                guard let self else {
                    return
                }
                self.lock.lock()
                let shouldRun = !self.closed
                    && self.prefetchGeneration == job.generation
                self.queuedPrefetchIndices.remove(job.index)
                self.lock.unlock()
                guard shouldRun else {
                    return
                }
                _ = self.decodeFrame(at: job.index)
            }
        }
    }

    private func cachedImage(at index: Int) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard var cached = frames[index] else {
            return nil
        }
        accessCounter &+= 1
        cached.lastAccess = accessCounter
        frames[index] = cached
        return cached.image
    }

    private func cancelQueuedPrefetch() {
        lock.lock()
        prefetchGeneration &+= 1
        queuedPrefetchIndices.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func insert(_ image: CGImage, at index: Int, cost: Int) {
        guard cost <= byteBudget else {
            return
        }
        if let previous = frames.removeValue(forKey: index) {
            totalCost -= previous.cost
        }
        while totalCost + cost > byteBudget,
              let key = frames.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            if let removed = frames.removeValue(forKey: key) {
                totalCost -= removed.cost
            }
        }
        accessCounter &+= 1
        frames[index] = CachedFrame(
            image: image,
            cost: cost,
            lastAccess: accessCounter
        )
        totalCost += cost
    }

    private static func frameDuration(
        source: CGImageSource,
        index: Int
    ) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            index,
            nil
        ) as NSDictionary? else {
            return 0.1
        }

        if let gif = properties.object(forKey: kCGImagePropertyGIFDictionary) as? NSDictionary {
            let unclamped = (gif.object(forKey: kCGImagePropertyGIFUnclampedDelayTime) as? NSNumber)?.doubleValue ?? 0
            let clamped = (gif.object(forKey: kCGImagePropertyGIFDelayTime) as? NSNumber)?.doubleValue ?? 0
            return max(0.02, unclamped > 0 ? unclamped : clamped > 0 ? clamped : 0.1)
        }

        if let webP = properties.object(forKey: kCGImagePropertyWebPDictionary) as? NSDictionary {
            let unclamped = (webP.object(forKey: kCGImagePropertyWebPUnclampedDelayTime) as? NSNumber)?.doubleValue ?? 0
            let clamped = (webP.object(forKey: kCGImagePropertyWebPDelayTime) as? NSNumber)?.doubleValue ?? 0
            return max(0.02, unclamped > 0 ? unclamped : clamped > 0 ? clamped : 0.1)
        }

        return 0.1
    }
}
