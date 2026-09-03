import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageViewerCore

@Test("Disk thumbnail cache persists and hits a stored thumbnail")
func diskThumbnailCachePersistsAndHitsStoredThumbnail() async throws {
    let directory = try makeTemporaryDirectory()
    let sourceURL = directory.appendingPathComponent("source.png")
    let cacheURL = directory.appendingPathComponent("cache", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try writePNG(to: sourceURL, image: makeTestImage(width: 64, height: 40))

    let firstCache = DiskThumbnailCache(rootURL: cacheURL, byteBudget: 1_000_000)
    let first = await firstCache.image(for: sourceURL, maxPixelSize: 16)
    let firstStats = await firstCache.stats()

    let secondCache = DiskThumbnailCache(rootURL: cacheURL, byteBudget: 1_000_000)
    let second = await secondCache.image(for: sourceURL, maxPixelSize: 16)
    let secondStats = await secondCache.stats()

    #expect(first?.width == 16)
    #expect(first?.height == 10)
    #expect(second?.width == 16)
    #expect(firstStats.missCount == 1)
    #expect(firstStats.writeCount == 1)
    #expect(secondStats.hitCount == 1)
    #expect(secondStats.missCount == 0)
}

@Test("Corrupt disk thumbnail is rebuilt from the source")
func corruptDiskThumbnailIsRebuiltFromSource() async throws {
    let directory = try makeTemporaryDirectory()
    let sourceURL = directory.appendingPathComponent("source.png")
    let cacheURL = directory.appendingPathComponent("cache", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try writePNG(to: sourceURL, image: makeTestImage(width: 32, height: 32))

    let cache = DiskThumbnailCache(rootURL: cacheURL, byteBudget: 1_000_000)
    let key = await cache.key(for: sourceURL, maxPixelSize: 16)
    let fileURL = await cache.cacheFileURL(for: key)
    try FileManager.default.createDirectory(
        at: cacheURL,
        withIntermediateDirectories: true
    )
    try Data("not a png".utf8).write(to: fileURL)

    let rebuilt = await cache.image(for: sourceURL, maxPixelSize: 16)
    let stats = await cache.stats()

    #expect(rebuilt != nil)
    #expect(stats.corruptedEntryCount == 1)
    #expect(stats.missCount == 1)
    #expect(stats.writeCount == 1)
}

@Test("Disk thumbnail cache removes expired entries")
func diskThumbnailCacheRemovesExpiredEntries() async throws {
    let directory = try makeTemporaryDirectory()
    let sourceURL = directory.appendingPathComponent("source.png")
    let cacheURL = directory.appendingPathComponent("cache", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try writePNG(to: sourceURL, image: makeTestImage(width: 32, height: 32))

    let cache = DiskThumbnailCache(rootURL: cacheURL, byteBudget: 1_000_000)
    _ = await cache.image(for: sourceURL, maxPixelSize: 16)
    let key = await cache.key(for: sourceURL, maxPixelSize: 16)
    let fileURL = await cache.cacheFileURL(for: key)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
        ofItemAtPath: fileURL.path
    )

    let refreshedCache = DiskThumbnailCache(
        rootURL: cacheURL,
        byteBudget: 1_000_000,
        maxAge: 1
    )
    let refreshed = await refreshedCache.image(for: sourceURL, maxPixelSize: 16)
    let stats = await refreshedCache.stats()

    #expect(refreshed != nil)
    #expect(stats.expiredEntryCount == 1)
    #expect(stats.writeCount == 1)
}

@Test("Disk thumbnail cache enforces its byte budget")
func diskThumbnailCacheEnforcesByteBudget() async throws {
    let directory = try makeTemporaryDirectory()
    let cacheURL = directory.appendingPathComponent("cache", isDirectory: true)
    let sourceA = directory.appendingPathComponent("a.png")
    let sourceB = directory.appendingPathComponent("b.png")
    defer { try? FileManager.default.removeItem(at: directory) }
    try writePNG(to: sourceA, image: makeTestImage(width: 128, height: 128))
    try writePNG(to: sourceB, image: makeTestImage(width: 128, height: 128, alternate: true))

    let cache = DiskThumbnailCache(rootURL: cacheURL, byteBudget: 1)
    _ = await cache.image(for: sourceA, maxPixelSize: 128)
    _ = await cache.image(for: sourceB, maxPixelSize: 128)
    let stats = await cache.stats()

    #expect(stats.currentBytes <= stats.byteBudget)
    #expect(stats.evictionCount >= 1)
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImageViewerDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func writePNG(to url: URL, image: CGImage) throws {
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

private func makeTestImage(
    width: Int,
    height: Int,
    alternate: Bool = false
) -> CGImage {
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
    if alternate {
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    }
    return context.makeImage()!
}
