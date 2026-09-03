import CoreGraphics
import Testing
@testable import ImageViewerCore

@Test("Canvas zoom keeps the image point below the cursor")
func canvasZoomKeepsAnchorStable() {
    let state = CanvasTransformState(
        mode: .actualSize,
        viewportSize: CGSize(width: 800, height: 600),
        imagePixelSize: CGSize(width: 1600, height: 1200)
    )
    let anchor = CGPoint(x: 280, y: 210)
    let imagePoint = CanvasTransformReducer.imagePoint(
        forViewPoint: anchor,
        in: state
    )!

    let zoomed = CanvasTransformReducer.reduce(
        state,
        .setScale(4, anchor: anchor)
    )
    let zoomedPoint = CanvasTransformReducer.viewPoint(
        forImagePoint: imagePoint,
        in: zoomed
    )

    #expect(abs(zoomedPoint.x - anchor.x) < 0.5)
    #expect(abs(zoomedPoint.y - anchor.y) < 0.5)
}

@Test("Canvas inverse mapping matches the displayed transform")
func canvasInverseMappingMatchesDisplayedTransform() {
    let state = CanvasTransformState(
        mode: .actualSize,
        scale: 2.5,
        translation: CGPoint(x: -180, y: 95),
        viewportSize: CGSize(width: 1200, height: 900),
        imagePixelSize: CGSize(width: 4000, height: 3000),
        rotationDegrees: 23,
        isFlippedHorizontally: true
    )
    let imagePoint = CGPoint(x: 620, y: -410)
    let direct = CanvasTransformReducer.viewPoint(
        forImagePoint: imagePoint,
        in: state
    )
    let transformed = imagePoint.applying(
        CanvasTransformReducer.viewTransform(for: state)
    )
    let recovered = CanvasTransformReducer.imagePoint(
        forViewPoint: direct,
        in: state
    )

    #expect(abs(direct.x - transformed.x) < 0.0001)
    #expect(abs(direct.y - transformed.y) < 0.0001)
    #expect(abs((recovered?.x ?? 0) - imagePoint.x) < 0.0001)
    #expect(abs((recovered?.y ?? 0) - imagePoint.y) < 0.0001)
}

@Test("Canvas translation is constrained in regular modes")
func canvasTranslationIsConstrained() {
    let state = CanvasTransformState(
        mode: .actualSize,
        translation: CGPoint(x: 5_000, y: -5_000),
        viewportSize: CGSize(width: 800, height: 600),
        imagePixelSize: CGSize(width: 1600, height: 1200)
    )
    let constrained = CanvasTransformReducer.reduce(
        state,
        .setTranslation(state.translation)
    )

    #expect(constrained.translation == CGPoint(x: 400, y: -300))
}

@Test("Canvas infinite mode preserves free translation")
func canvasInfiniteModePreservesFreeTranslation() {
    let state = CanvasTransformState(
        mode: .infinite,
        viewportSize: CGSize(width: 800, height: 600),
        imagePixelSize: CGSize(width: 1600, height: 1200)
    )
    let translated = CanvasTransformReducer.reduce(
        state,
        .setTranslation(CGPoint(x: 5_000, y: -5_000))
    )

    #expect(translated.translation == CGPoint(x: 5_000, y: -5_000))
}

@Test("Canvas scale remains monotonic for same direction inputs")
func canvasScaleRemainsMonotonic() {
    var state = CanvasTransformState(mode: .actualSize)
    var scales: [CGFloat] = []

    for _ in 0..<1000 {
        state = CanvasTransformReducer.reduce(
            state,
            .setScale(state.scale * 1.01, anchor: nil)
        )
        scales.append(state.scale)
    }

    #expect(scales.allSatisfy { $0 >= 1 })
    #expect(scales.allSatisfy { $0 <= CanvasTransformReducer.maximumScale })
    #expect(zip(scales, scales.dropFirst()).allSatisfy { $0 <= $1 })
}

@Test("Canvas rotation changes fitted bounds without changing scale state")
func canvasRotationChangesFittedBounds() {
    let state = CanvasTransformState(
        viewportSize: CGSize(width: 800, height: 600),
        imagePixelSize: CGSize(width: 1600, height: 800)
    )
    let rotated = CanvasTransformReducer.reduce(state, .setRotation(90))

    #expect(rotated.scale == state.scale)
    let rotatedSize = CanvasTransformReducer.rotatedImageSize(for: rotated)
    #expect(abs(rotatedSize.width - 800) < 0.5)
    #expect(abs(rotatedSize.height - 1600) < 0.5)
}

@Test("Canvas translation moves the minimap viewport with the image")
func canvasTranslationMovesTheMinimapViewportWithTheImage() {
    let state = CanvasTransformState(
        mode: .actualSize,
        viewportSize: CGSize(width: 800, height: 600),
        imagePixelSize: CGSize(width: 4000, height: 3000)
    )
    let centered = CanvasTransformReducer.normalizedViewport(for: state)
    let shiftedState = CanvasTransformReducer.reduce(
        state,
        .setTranslation(CGPoint(x: 240, y: 120))
    )
    let shifted = CanvasTransformReducer.normalizedViewport(for: shiftedState)

    #expect(centered != nil)
    #expect(shifted != nil)
    #expect(shifted?.size == centered?.size)
    #expect((shifted?.midX ?? 0) < (centered?.midX ?? 0))
    #expect((shifted?.midY ?? 0) < (centered?.midY ?? 0))
}

@Test("Minimap viewport center round-trips a canvas viewport move")
func minimapViewportCenterRoundTripsACanvasViewportMove() {
    let state = CanvasTransformState(
        mode: .actualSize,
        scale: 2,
        viewportSize: CGSize(width: 800, height: 600),
        imagePixelSize: CGSize(width: 4000, height: 3000),
        rotationDegrees: 17
    )
    let requestedCenter = CGPoint(x: 0.72, y: 0.64)
    let movedState = CanvasTransformReducer.reduce(
        state,
        .moveViewport(center: requestedCenter)
    )
    let viewport = CanvasTransformReducer.normalizedViewport(for: movedState)

    #expect(viewport != nil)
    #expect(abs((viewport?.midX ?? 0) - requestedCenter.x) < 0.0001)
    #expect(abs((viewport?.midY ?? 0) - requestedCenter.y) < 0.0001)
}
