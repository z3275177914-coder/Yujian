import CoreGraphics
import Dispatch
import Foundation
import Testing
@testable import ImageViewerCore

@Test("Image render service reuses one context and records its working color space")
func imageRenderServiceReusesOneContextAndRecordsWorkingColorSpace() {
    let service = ImageRenderService()
    let contextIdentifier = service.contextIdentifier
    let image = makeRenderTestImage(width: 64, height: 48)

    let first = service.renderLatest(
        to: image,
        adjustments: ImageAdjustments(brightness: 0.2),
        quality: .settled
    )
    let second = service.renderLatest(
        to: image,
        adjustments: ImageAdjustments(contrast: 1.2),
        quality: .settled
    )

    #expect(service.contextIdentifier == contextIdentifier)
    #expect(service.workingColorSpaceName == "sRGB")
    #expect(first?.width == image.width)
    #expect(second?.height == image.height)
}

@Test("Interactive rendering keeps source dimensions after a low resolution pass")
func interactiveRenderingKeepsSourceDimensionsAfterLowResolutionPass() {
    let service = ImageRenderService()
    let image = makeRenderTestImage(width: 2_560, height: 1_440)

    let rendered = service.renderLatest(
        to: image,
        adjustments: ImageAdjustments(saturation: 1.2),
        quality: .interactive
    )

    #expect(rendered?.width == image.width)
    #expect(rendered?.height == image.height)
}

@Test("Latest-wins gate invalidates every older revision")
func latestWinsGateInvalidatesEveryOlderRevision() {
    let gate = LatestWinsRenderGate()
    let collector = RevisionCollector()

    DispatchQueue.concurrentPerform(iterations: 100) { _ in
        let revision = gate.begin()
        collector.append(revision)
    }

    let revisions = collector.values
    #expect(revisions.count == 100)
    #expect(revisions.filter(gate.isCurrent).count == 1)
}

private final class RevisionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [UInt64] = []

    func append(_ revision: UInt64) {
        lock.lock()
        storedValues.append(revision)
        lock.unlock()
    }

    var values: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }
}

private func makeRenderTestImage(width: Int, height: Int) -> CGImage {
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
    context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}
