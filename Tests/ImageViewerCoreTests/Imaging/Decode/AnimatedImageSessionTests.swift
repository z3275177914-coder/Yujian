import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageViewerCore

@Test("Animated image session decodes a bounded frame window on demand")
func animatedImageSessionDecodesBoundedFrameWindow() async throws {
    let directory = try makeTemporaryDirectory()
    let gifURL = directory.appendingPathComponent("window.gif")
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeGIF(to: gifURL, frameCount: 64)

    let session = try #require(await AnimatedImageSession.open(
        url: gifURL,
        maxPixelSize: 64,
        windowSize: 1,
        byteBudget: 12 * 12 * 4 * 2
    ))
    let firstFrame = await session.image(at: 0)
    let stats = session.stats()

    #expect(firstFrame?.width == 12)
    #expect(session.frameCount == 64)
    #expect(stats.cachedFrameCount < stats.frameCount)
    #expect(stats.currentCost <= stats.byteBudget)
    #expect(session.duration(at: 0) == 0.05)
    #expect(session.duration(at: 1) == 0.2)
}

@Test("Closing an animated image session releases frames and rejects requests")
func closingAnimatedImageSessionReleasesFramesAndRejectsRequests() async throws {
    let directory = try makeTemporaryDirectory()
    let gifURL = directory.appendingPathComponent("close.gif")
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeGIF(to: gifURL, frameCount: 4)

    let session = try #require(await AnimatedImageSession.open(url: gifURL))
    let pending = Task {
        await session.image(at: 1)
    }
    session.close()

    let result = await pending.value
    let stats = session.stats()
    #expect(result == nil)
    #expect(stats.isClosed)
    #expect(stats.cachedFrameCount == 0)
    #expect(await session.image(at: 0) == nil)
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImageViewerAnimationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func writeGIF(to url: URL, frameCount: Int) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.gif.identifier as CFString,
        frameCount,
        nil
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    for index in 0..<frameCount {
        let context = CGContext(
            data: nil,
            width: 12,
            height: 12,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let shade = CGFloat(index.isMultiple(of: 2) ? 0.2 : 0.8)
        context.setFillColor(CGColor(gray: shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        CGImageDestinationAddImage(
            destination,
            context.makeImage()!,
            [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: index == 0 ? 0.05 : 0.2
                ]
            ] as CFDictionary
        )
    }

    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}
