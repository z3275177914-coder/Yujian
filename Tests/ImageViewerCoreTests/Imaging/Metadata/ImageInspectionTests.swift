import CoreGraphics
import Foundation
import Testing
@testable import ImageViewerCore

@Test("Histogram computation stays on a bounded bin set and counts every pixel")
func histogramCountsEveryPixel() {
    let image = makeInspectionImage()
    let histogram = ImageHistogramService.compute(image: image, binCount: 16)

    #expect(histogram.binCount == 16)
    #expect(histogram.totalPixels == 4)
    #expect(histogram.red.reduce(0, +) == 4)
    #expect(histogram.green.reduce(0, +) == 4)
    #expect(histogram.blue.reduce(0, +) == 4)
    #expect(histogram.luminance.reduce(0, +) == 4)
}

@Test("Pixel sampler returns a stable RGBA sample and hex label")
func pixelSamplerReturnsRGBA() {
    let image = makeSinglePixelImage(red: 10, green: 20, blue: 30, alpha: 255)
    let sample = PixelSampler.sample(image: image, at: CGPoint(x: 0.5, y: 0.5))

    #expect(sample?.red == 10)
    #expect(sample?.green == 20)
    #expect(sample?.blue == 30)
    #expect(sample?.alpha == 255)
    #expect(sample?.hexadecimal == "#0A141E")
}

private func makeInspectionImage() -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil,
        width: 2,
        height: 2,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
    context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
    return context.makeImage()!
}

private func makeSinglePixelImage(red: Int, green: Int, blue: Int, alpha: Int) -> CGImage {
    let data = Data([UInt8(red), UInt8(green), UInt8(blue), UInt8(alpha)])
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}
