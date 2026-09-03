import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageViewerCore

@Test("Image export converts and resizes an image")
func imageExportConvertsAndResizes() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("source.png")
    let destinationURL = directory.appendingPathComponent("result.jpg")
    try makePNG(at: sourceURL, width: 20, height: 10)

    try ImageExportService.export(
        sourceURL: sourceURL,
        destinationURL: destinationURL,
        format: .jpeg,
        options: ImageExportOptions(
            width: 8,
            height: 8,
            keepAspectRatio: false
        )
    )

    let source = CGImageSourceCreateWithURL(destinationURL as CFURL, nil)
    let properties = CGImageSourceCopyPropertiesAtIndex(source!, 0, nil) as NSDictionary?
    let width = (properties?.object(forKey: kCGImagePropertyPixelWidth) as? NSNumber)?.intValue
    let height = (properties?.object(forKey: kCGImagePropertyPixelHeight) as? NSNumber)?.intValue
    #expect(width == 8)
    #expect(height == 8)
}

@Test("Image export applies the edit recipe before resizing")
func imageExportAppliesEditRecipe() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("source.png")
    let destinationURL = directory.appendingPathComponent("edited.png")
    try makePNG(at: sourceURL, width: 20, height: 10)

    try ImageExportService.export(
        sourceURL: sourceURL,
        destinationURL: destinationURL,
        format: .png,
        recipe: EditRecipe(
            adjustments: ImageAdjustments(brightness: 0.2),
            rotationDegrees: 90,
            cropRect: EditCropRect(x: 0, y: 0, width: 0.25, height: 1)
        )
    )

    let source = CGImageSourceCreateWithURL(destinationURL as CFURL, nil)
    let properties = CGImageSourceCopyPropertiesAtIndex(source!, 0, nil) as NSDictionary?
    let width = (properties?.object(forKey: kCGImagePropertyPixelWidth) as? NSNumber)?.intValue
    let height = (properties?.object(forKey: kCGImagePropertyPixelHeight) as? NSNumber)?.intValue
    #expect(width == 10)
    #expect(height == 5)
}

@Test("Failed export leaves an existing destination untouched")
func failedExportLeavesExistingDestinationUntouched() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("missing.png")
    let destinationURL = directory.appendingPathComponent("existing.png")
    let originalData = Data("keep me".utf8)
    try originalData.write(to: destinationURL)

    do {
        try ImageExportService.export(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            format: .png
        )
        Issue.record("Expected invalid source error")
    } catch {
        #expect(try Data(contentsOf: destinationURL) == originalData)
    }
}

@Test("Export metadata policy can remove GPS without changing the source")
func exportMetadataPolicyCanRemoveGPS() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("source.tiff")
    let preservedURL = directory.appendingPathComponent("preserved.tiff")
    let privateURL = directory.appendingPathComponent("private.tiff")
    try makeImage(
        at: sourceURL,
        format: UTType.tiff.identifier,
        properties: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.2,
                kCGImagePropertyGPSLongitude: 121.5
            ]
        ] as CFDictionary
    )

    try ImageExportService.export(
        sourceURL: sourceURL,
        destinationURL: preservedURL,
        format: .tiff,
        options: ImageExportOptions(metadataPolicy: .preserve)
    )
    try ImageExportService.export(
        sourceURL: sourceURL,
        destinationURL: privateURL,
        format: .tiff,
        options: ImageExportOptions(metadataPolicy: .stripPrivateLocation)
    )

    let sourceProperties = CGImageSourceCopyPropertiesAtIndex(
        CGImageSourceCreateWithURL(sourceURL as CFURL, nil)!, 0, nil
    ) as NSDictionary?
    let preservedProperties = CGImageSourceCopyPropertiesAtIndex(
        CGImageSourceCreateWithURL(preservedURL as CFURL, nil)!, 0, nil
    ) as NSDictionary?
    let privateProperties = CGImageSourceCopyPropertiesAtIndex(
        CGImageSourceCreateWithURL(privateURL as CFURL, nil)!, 0, nil
    ) as NSDictionary?

    #expect(sourceProperties?.object(forKey: kCGImagePropertyGPSDictionary) != nil)
    #expect(preservedProperties?.object(forKey: kCGImagePropertyGPSDictionary) != nil)
    #expect(privateProperties?.object(forKey: kCGImagePropertyGPSDictionary) == nil)
}

@Test("Batch rename stages files before applying names")
func batchRenameStagesFiles() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstURL = directory.appendingPathComponent("one.png")
    let secondURL = directory.appendingPathComponent("two.jpg")
    try Data().write(to: firstURL)
    try Data().write(to: secondURL)

    let renamed = try FileBatchService.rename(
        assets: [ImageAsset(url: secondURL), ImageAsset(url: firstURL)],
        options: BatchRenameOptions(prefix: "旅行", startNumber: 7, minimumDigits: 2)
    )

    #expect(renamed.map(\.lastPathComponent) == ["旅行-07.png", "旅行-08.jpg"])
    #expect(FileManager.default.fileExists(atPath: renamed[0].path))
    #expect(FileManager.default.fileExists(atPath: renamed[1].path))
}

@Test("Animated decoder loads multiple GIF frames")
func animatedDecoderLoadsGIFFrames() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let gifURL = directory.appendingPathComponent("animated.gif")
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let destination = CGImageDestinationCreateWithURL(
        gifURL as CFURL,
        UTType.gif.identifier as CFString,
        2,
        nil
    )!

    for gray in [0.2, 0.8] {
        let context = CGContext(
            data: nil,
            width: 12,
            height: 12,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    }
    #expect(CGImageDestinationFinalize(destination))

    let animation = ImageDecoder.decodeAnimation(url: gifURL, maxPixelSize: 64)
    #expect(animation?.frames.count == 2)
    #expect(animation?.durations.count == 2)
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImageViewerExportTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func makePNG(at url: URL, width: Int, height: Int) throws {
    try makeImage(at: url, format: UTType.png.identifier, width: width, height: height)
}

private func makeImage(
    at url: URL,
    format: String,
    width: Int = 20,
    height: Int = 10,
    properties: CFDictionary? = nil
) throws {
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
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        format as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(destination, image, properties)
    #expect(CGImageDestinationFinalize(destination))
}
