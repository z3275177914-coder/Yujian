import CoreGraphics
import Testing
@testable import ImageViewerCore

@Test("Image adjustments preserve dimensions and clamp values")
func imageAdjustmentsPreserveDimensionsAndClampValues() {
    let image = makeAdjustmentTestImage()
    let adjusted = ImageAdjustmentService.apply(
        to: image,
        adjustments: ImageAdjustments(
            brightness: 4,
            contrast: -1,
            saturation: 3,
            sharpness: 0.8
        )
    )

    #expect(adjusted?.width == image.width)
    #expect(adjusted?.height == image.height)

    let clamped = ImageAdjustments(
        brightness: 4,
        contrast: -1,
        saturation: 3,
        sharpness: 0.8
    ).clamped
    #expect(clamped.brightness == 1)
    #expect(clamped.contrast == 0)
    #expect(clamped.saturation == 2)
    #expect(clamped.sharpness == 0.8)
}

@Test("Extended image adjustments clamp to their documented ranges")
func extendedImageAdjustmentsClampToDocumentedRanges() {
    let clamped = ImageAdjustments(
        exposure: 9,
        highlights: -3,
        shadows: 3,
        temperature: -2,
        tint: 2
    ).clamped

    #expect(clamped.exposure == 2)
    #expect(clamped.highlights == -1)
    #expect(clamped.shadows == 1)
    #expect(clamped.temperature == -1)
    #expect(clamped.tint == 1)
}

@Test("Normalized crop uses top-left coordinates and preserves the selected size")
func normalizedCropUsesTopLeftCoordinates() {
    let image = makeAdjustmentTestImage()
    let cropped = ImageAdjustmentService.crop(
        image,
        to: EditCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    )

    #expect(cropped?.width == 12)
    #expect(cropped?.height == 8)
}

@Test("Default image adjustments reuse the source image")
func defaultImageAdjustmentsReuseSourceImage() {
    let image = makeAdjustmentTestImage()
    let adjusted = ImageAdjustmentService.apply(to: image, adjustments: .default)

    #expect(adjusted === image)
}

private func makeAdjustmentTestImage() -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil,
        width: 24,
        height: 16,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
    return context.makeImage()!
}
