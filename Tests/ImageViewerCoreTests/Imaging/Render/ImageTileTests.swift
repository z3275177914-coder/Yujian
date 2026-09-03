import CoreGraphics
import Testing
@testable import ImageViewerCore

@Test("Tile descriptor clamps edge tiles and keeps visible requests local")
func tileDescriptorClampsEdgeTiles() {
    let descriptor = ImageTileDescriptor(
        pixelWidth: 1_025,
        pixelHeight: 769,
        tileSize: 512,
        proxyMaxPixelSize: 512
    )

    #expect(descriptor.tileGridSize(at: 0) == ImageTileGridSize(columns: 3, rows: 2))
    #expect(descriptor.pixelRect(for: ImageTileCoordinate(level: 0, column: 2, row: 1)) == CGRect(
        x: 1_024,
        y: 512,
        width: 1,
        height: 257
    ))

    let boundaryTiles = descriptor.tiles(
        intersecting: CGRect(x: 512, y: 0, width: 1, height: 1),
        at: 0
    )
    #expect(boundaryTiles == [ImageTileCoordinate(level: 0, column: 1, row: 0)])
}

@Test("Tile descriptor selects stable powers-of-two LODs")
func tileDescriptorSelectsStableLODs() {
    let descriptor = ImageTileDescriptor(
        pixelWidth: 20_000,
        pixelHeight: 12_000,
        tileSize: 512,
        proxyMaxPixelSize: 4_096
    )

    #expect(descriptor.maximumLevel == 3)
    #expect(descriptor.downsampledPixelSize(at: 2) == ImageTilePixelSize(width: 5_000, height: 3_000))
    #expect(descriptor.level(forEffectiveScale: 4) == 0)
    #expect(descriptor.level(forEffectiveScale: 1) == 0)
    #expect(descriptor.level(forEffectiveScale: 0.125) == 3)
    #expect(descriptor.level(forEffectiveScale: .nan) == descriptor.maximumLevel)
}

@Test("Tile geometry supports rotated source bounds")
func tileGeometrySupportsRotatedSourceBounds() {
    #expect(ImageTileDescriptor.rotatedPixelSize(
        width: 1_600,
        height: 800,
        degrees: 90
    ) == ImageTilePixelSize(width: 800, height: 1_600))

    let representation = ImageRepresentation(
        pixelWidth: 9_000,
        pixelHeight: 9_000
    )
    #expect(representation.isLargeImage)
    #expect(representation.tileDescriptor.pixelSize == representation.pixelSize)
}

@Test("Interactive image budget routes common 6K sources through tiles")
func interactiveImageBudgetRoutesCommon6KSourcesThroughTiles() {
    #expect(ImageTilePixelSize(width: 6_000, height: 4_000).isLargeImage)
    #expect(ImageTilePixelSize(width: 2_048, height: 2_048).isLargeImage == false)
    #expect(ImageTilePixelSize(width: 4_096, height: 4_096).isLargeImage)
    #expect(ImageTilePixelSize(width: 8_000, height: 4_100).isLargeImage)
}

@Test("Detail decode size stays bounded for very large sources")
func detailDecodeSizeStaysBoundedForVeryLargeSources() {
    let detailSize = ImageTilePixelSize.detailDecodeMaxPixelSize(
        for: ImageTilePixelSize(width: 12_000, height: 8_000)
    )

    #expect(detailSize <= ImageTilePixelSize.detailMaxPixelSize)
    #expect(detailSize > ImageTilePixelSize.interactiveMaxPixelSize)
    #expect(
        ImageTilePixelSize.detailDecodeMaxPixelSize(
            for: ImageTilePixelSize(width: 1_024, height: 768)
        ) == 1_024
    )
}

@Test("Proxy tiles map source coordinates when the detail bitmap is smaller")
func proxyTilesMapSourceCoordinatesWhenDetailBitmapIsSmaller() {
    let proxy = makeTileTestImage(width: 300, height: 200)
    let descriptor = ImageTileDescriptor(
        pixelWidth: 600,
        pixelHeight: 400,
        tileSize: 512,
        proxyMaxPixelSize: 512
    )
    let provider = ImageTileProvider(
        descriptor: descriptor,
        proxyImage: proxy
    )

    let edge = provider.image(for: ImageTileCoordinate(level: 0, column: 1, row: 0))
    #expect(edge?.width == 44)
    #expect(edge?.height == 200)
}

@Test("Detail provider exposes one stable representation")
func detailProviderExposesOneStableRepresentation() {
    let image = makeTileTestImage(width: 2_048, height: 1_024)
    let descriptor = ImageTileDescriptor(
        pixelWidth: 2_048,
        pixelHeight: 1_024,
        tileSize: 512,
        proxyMaxPixelSize: 512
    )
    let provider = ImageTileProvider(
        descriptor: descriptor,
        proxyImage: image
    )

    #expect(provider.detailImageIfAvailable() === image)
}

@Test("100 MP tile descriptor keeps the visible tile set bounded")
func hundredMegapixelTileDescriptorKeepsVisibleTileSetBounded() {
    let descriptor = ImageTileDescriptor(
        pixelWidth: 10_000,
        pixelHeight: 10_000,
        tileSize: 512,
        proxyMaxPixelSize: 4_096
    )
    let visibleTiles = descriptor.tiles(
        intersecting: CGRect(x: 4_800, y: 4_800, width: 400, height: 400),
        at: 0
    )

    #expect(descriptor.pixelSize.pixelCount == 100_000_000)
    #expect(descriptor.tileGridSize(at: 0) == ImageTileGridSize(columns: 20, rows: 20))
    #expect(visibleTiles.count == 4)
}

@Test("Tile request gate invalidates stale revisions")
func tileRequestGateInvalidatesStaleRevisions() {
    let gate = ImageTileRequestGate()
    let firstRevision = gate.begin()
    #expect(gate.isCurrent(firstRevision))

    gate.cancel()
    #expect(!gate.isCurrent(firstRevision))

    let secondRevision = gate.begin()
    #expect(gate.isCurrent(secondRevision))
    #expect(!gate.isCurrent(firstRevision))
}

@Test("Tile provider returns a correctly clipped proxy edge tile")
func tileProviderReturnsClippedProxyEdgeTile() {
    let proxy = makeTileTestImage(width: 512, height: 384)
    let descriptor = ImageTileDescriptor(
        pixelWidth: 1_025,
        pixelHeight: 769,
        tileSize: 512,
        proxyMaxPixelSize: 512
    )
    let provider = ImageTileProvider(
        descriptor: descriptor,
        proxyImage: proxy
    )

    let edge = provider.image(for: ImageTileCoordinate(level: 0, column: 2, row: 1))
    #expect(edge?.width == 1)
    #expect(edge?.height == 129)
}

@Test("Tile provider keeps cached tiles within its byte budget")
func tileProviderKeepsCachedTilesWithinByteBudget() {
    let image = makeTileTestImage(width: 1_024, height: 1_024)
    let descriptor = ImageTileDescriptor(
        pixelWidth: 1_024,
        pixelHeight: 1_024,
        tileSize: 512,
        proxyMaxPixelSize: 512
    )
    let provider = ImageTileProvider(
        descriptor: descriptor,
        proxyImage: image,
        byteBudget: 512 * 512 * 4
    )

    _ = provider.image(for: ImageTileCoordinate(level: 0, column: 0, row: 0))
    _ = provider.image(for: ImageTileCoordinate(level: 0, column: 1, row: 0))
    let stats = provider.stats()

    #expect(stats.currentCost <= stats.byteBudget)
    #expect(stats.cachedTileCount <= 1)
}

private func makeTileTestImage(width: Int, height: Int) -> CGImage {
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
