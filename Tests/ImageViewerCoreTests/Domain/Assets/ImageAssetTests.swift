import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ImageViewerCore

@Test("Image asset recognizes supported image extensions")
func imageAssetRecognizesSupportedExtensions() {
    #expect(ImageAsset.isSupportedImage(URL(fileURLWithPath: "/tmp/photo.HEIC")))
    #expect(ImageAsset.isSupportedImage(URL(fileURLWithPath: "/tmp/photo.webp")))
    #expect(!ImageAsset.isSupportedImage(URL(fileURLWithPath: "/tmp/readme.txt")))
}

@Test("Image asset exposes normalized file information")
func imageAssetExposesFileInformation() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("image-viewer-asset-test.png")
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let asset = ImageAsset(url: url)

    #expect(asset.filename == "image-viewer-asset-test.png")
    #expect(asset.fileExtension == "png")
    #expect(asset.fileSize == 0)
    #expect(asset.dimensionsLabel == "未知")
}

@Test("JPEG display dimensions and decoded pixels use the same EXIF orientation")
func jpegDisplayDimensionsMatchDecodedOrientation() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("image-viewer-orientation-test.jpg")
    defer { try? FileManager.default.removeItem(at: url) }

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil,
        width: 400,
        height: 200,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))

    let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        "public.jpeg" as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(
        destination,
        context.makeImage()!,
        [kCGImagePropertyOrientation: 6] as CFDictionary
    )
    #expect(CGImageDestinationFinalize(destination))

    let asset = ImageAsset(url: url)
    let decoded = ImageDecoder.decodeCGImage(url: url, maxPixelSize: nil)
    let proxy = ImageDecoder.decodeCGImage(url: url, maxPixelSize: 100)

    #expect(asset.pixelWidth == 200)
    #expect(asset.pixelHeight == 400)
    #expect(decoded?.width == 200)
    #expect(decoded?.height == 400)
    #expect(proxy?.width == 50)
    #expect(proxy?.height == 100)
}
