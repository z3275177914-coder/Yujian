import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageViewerCore

@Test("Image cache key changes when the source file changes")
func imageCacheKeyChangesWhenTheSourceFileChanges() async throws {
    let cache = ImageDecodeCache(byteBudget: 2 * 1024 * 1024)
    let url = try makeTemporaryImage(width: 40, height: 24)
    defer { try? FileManager.default.removeItem(at: url) }

    let initialKey = await cache.key(for: url, maxPixelSize: nil)
    let initial = await cache.image(for: url, maxPixelSize: nil)
    let cached = await cache.image(for: url, maxPixelSize: nil)

    try? await Task.sleep(nanoseconds: 2_000_000)
    try writePNG(to: url, width: 80, height: 24)
    let changedKey = await cache.key(for: url, maxPixelSize: nil)
    let changed = await cache.image(for: url, maxPixelSize: nil)
    let stats = await cache.stats()

    #expect(initial?.width == 40)
    #expect(cached?.width == 40)
    #expect(initialKey != changedKey)
    #expect(changed?.width == 80)
    #expect(stats.hitCount >= 1)
    #expect(stats.missCount == 2)
}

@Test("Image cache coalesces concurrent decodes for one key")
func imageCacheCoalescesConcurrentDecodesForOneKey() async {
    let image = makeCacheTestImage(width: 64, height: 64)
    let gate = DecodeGate()
    let cache = ImageDecodeCache(
        decoder: { _, _ in
            gate.started.signal()
            gate.proceed.wait()
            return image
        }
    )
    let url = URL(fileURLWithPath: "/tmp/image-viewer-cache-coalesced.png")

    let firstTask = Task {
        await cache.image(for: url, maxPixelSize: nil)
    }
    await Task.yield()
    await gate.waitUntilStarted()
    let secondTask = Task {
        await cache.image(for: url, maxPixelSize: nil)
    }

    var didCoalesce = false
    for _ in 0..<2_000 {
        if await cache.stats().coalescedRequestCount == 1 {
            didCoalesce = true
            break
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    gate.proceed.signal()

    _ = await firstTask.value
    _ = await secondTask.value
    let stats = await cache.stats()

    #expect(didCoalesce)
    #expect(stats.coalescedRequestCount == 1)
    #expect(stats.entryCount == 1)
}

@Test("Image cache keeps byte usage within its LRU budget")
func imageCacheKeepsByteUsageWithinItsLRUBudget() async {
    let imageA = makeCacheTestImage(width: 32, height: 32)
    let imageB = makeCacheTestImage(width: 32, height: 32)
    let cache = ImageDecodeCache(
        byteBudget: 32 * 32 * 4,
        decoder: { url, _ in
            url.lastPathComponent.contains("a") ? imageA : imageB
        }
    )
    let urlA = URL(fileURLWithPath: "/tmp/image-viewer-cache-a.png")
    let urlB = URL(fileURLWithPath: "/tmp/image-viewer-cache-b.png")

    _ = await cache.image(for: urlA, maxPixelSize: nil)
    _ = await cache.image(for: urlB, maxPixelSize: nil)
    let stats = await cache.stats()

    #expect(stats.currentCost <= stats.byteBudget)
    #expect(stats.entryCount == 1)
    #expect(stats.evictionCount == 1)
}

@Test("Image cache cancellation does not publish a cancelled request")
func imageCacheCancellationDoesNotPublishACancelledRequest() async {
    let image = makeCacheTestImage(width: 64, height: 64)
    let cache = ImageDecodeCache(
        decoder: { _, _ in
            Thread.sleep(forTimeInterval: 0.08)
            return image
        }
    )
    let task = Task {
        await cache.image(
            for: URL(fileURLWithPath: "/tmp/image-viewer-cache-cancelled.png"),
            maxPixelSize: nil
        )
    }
    await Task.yield()
    task.cancel()

    let result = await task.value
    let stats = await cache.stats()

    #expect(result == nil)
    #expect(stats.cancellationCount == 1)
}

@Test("Clearing image cache prevents an older decode from repopulating it")
func clearingImageCachePreventsOlderDecodeFromRepopulatingIt() async {
    let image = makeCacheTestImage(width: 64, height: 64)
    let gate = DecodeGate()
    let cache = ImageDecodeCache(
        decoder: { _, _ in
            gate.started.signal()
            gate.proceed.wait()
            return image
        }
    )
    let url = URL(fileURLWithPath: "/tmp/image-viewer-cache-cleared.png")

    let task = Task {
        await cache.image(for: url, maxPixelSize: nil)
    }
    await gate.waitUntilStarted()
    await cache.removeAll()
    gate.proceed.signal()
    _ = await task.value

    let stats = await cache.stats()
    #expect(stats.entryCount == 0)
    #expect(stats.currentCost == 0)
}

@Test("Prefetch records direction and can be cancelled")
func prefetchRecordsDirectionAndCanBeCancelled() async {
    let image = makeCacheTestImage(width: 24, height: 24)
    let cache = ImageDecodeCache(
        decoder: { _, _ in image }
    )
    let urls = [
        URL(fileURLWithPath: "/tmp/image-viewer-prefetch-1.png"),
        URL(fileURLWithPath: "/tmp/image-viewer-prefetch-2.png")
    ]

    await cache.prefetch(
        urls: urls,
        maxPixelSize: 64,
        direction: .backward
    )
    let startedStats = await cache.stats()
    await cache.cancelPrefetch()
    let cancelledStats = await cache.stats()

    #expect(startedStats.lastPrefetchDirection == .backward)
    #expect(cancelledStats.inFlightCount == 0 || cancelledStats.inFlightCount == 1)
}

@Test("Memory pressure trim releases at least half of the cache budget")
func memoryPressureTrimReleasesAtLeastHalfOfTheCacheBudget() async {
    let image = makeCacheTestImage(width: 32, height: 32)
    let cache = ImageDecodeCache(
        byteBudget: 2 * 32 * 32 * 4,
        decoder: { _, _ in image }
    )
    _ = await cache.image(
        for: URL(fileURLWithPath: "/tmp/image-viewer-cache-memory-a.png"),
        maxPixelSize: nil
    )
    _ = await cache.image(
        for: URL(fileURLWithPath: "/tmp/image-viewer-cache-memory-b.png"),
        maxPixelSize: nil
    )

    await cache.trimForMemoryPressure()
    let stats = await cache.stats()

    #expect(stats.currentCost <= stats.byteBudget / 2)
    #expect(stats.memoryPressureTrimCount == 1)
}

private func makeTemporaryImage(width: Int, height: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("image-viewer-cache-(UUID().uuidString).png")
    try writePNG(to: url, width: width, height: height)
    return url
}

private func writePNG(to url: URL, width: Int, height: Int) throws {
    let image = makeCacheTestImage(width: width, height: height)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func makeCacheTestImage(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private final class DecodeGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.started.wait()
                continuation.resume()
            }
        }
    }
}
