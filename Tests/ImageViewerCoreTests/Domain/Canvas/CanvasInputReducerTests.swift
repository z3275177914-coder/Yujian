import CoreGraphics
import Testing
@testable import ImageViewerCore

@Test("Discrete wheel input is monotonic and sensitivity-aware")
func discreteWheelInputIsMonotonicAndSensitivityAware() {
        let low = CanvasInputReducer.zoomMultiplier(
            delta: 1,
            isPrecise: false,
            sensitivity: 0.5
        )
        let high = CanvasInputReducer.zoomMultiplier(
            delta: 1,
            isPrecise: false,
            sensitivity: 2
        )

        #expect(low > 1)
        #expect(high > low)
        #expect(high <= 1.5 + 0.0001)
        let reverse = CanvasInputReducer.zoomMultiplier(
            delta: -1,
            isPrecise: false,
            sensitivity: 2
        )
        #expect(abs(reverse - 1 / high) < 0.0001)
}

@Test("Precise input preserves device delta instead of mouse sensitivity")
func preciseInputPreservesDeviceDeltaInsteadOfMouseSensitivity() {
        let low = CanvasInputReducer.zoomMultiplier(
            delta: 2,
            isPrecise: true,
            sensitivity: 0.25
        )
        let high = CanvasInputReducer.zoomMultiplier(
            delta: 2,
            isPrecise: true,
            sensitivity: 3
        )

        #expect(abs(low - high) < 0.0001)
        #expect(low > 1)
}

@Test("Large wheel delta has a single-event limit")
func largeWheelDeltaHasASingleEventLimit() {
        let zoomIn = CanvasInputReducer.zoomMultiplier(
            delta: 10_000,
            isPrecise: false,
            sensitivity: 3
        )
        let zoomOut = CanvasInputReducer.zoomMultiplier(
            delta: -10_000,
            isPrecise: false,
            sensitivity: 3
        )

        #expect(abs(zoomIn - 1.5) < 0.0001)
        #expect(abs(zoomOut - 1 / 1.5) < 0.0001)
}

@Test("Viewport center clamps to edges")
func viewportCenterClampsToEdges() {
        let viewport = CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.4)
        let center = CanvasViewportReducer.clampedCenter(
            CGPoint(x: 4, y: -3),
            for: viewport
        )

        #expect(abs(center.x - 0.75) < 0.0001)
        #expect(abs(center.y - 0.2) < 0.0001)
}

@Test("Minimap drag uses a fixed viewport size and clamps its target")
func minimapDragUsesFixedViewportSizeAndClampsItsTarget() {
        let viewport = CGRect(x: 0.2, y: 0.25, width: 0.3, height: 0.2)
        let startPoint = CGPoint(x: 0.35, y: 0.35)
        let target = CanvasViewportReducer.draggedCenter(
            for: viewport,
            from: startPoint,
            to: CGPoint(x: 1.5, y: -1)
        )
        let displayed = CanvasViewportReducer.centeredViewport(
            around: target,
            size: viewport.size
        )

        #expect(displayed.size == viewport.size)
        #expect(displayed.minX >= 0)
        #expect(displayed.minY >= 0)
        #expect(displayed.maxX <= 1)
        #expect(displayed.maxY <= 1)
}

@Test("Sensitivity and input remain stable above twenty times zoom")
func sensitivityAndInputRemainStableAboveTwentyTimesZoom() {
        var scale: CGFloat = 1
        for _ in 0..<200 {
            scale = min(
                CanvasTransformReducer.maximumScale,
                scale * CanvasInputReducer.zoomMultiplier(
                    delta: 1,
                    isPrecise: false,
                    sensitivity: 3
                )
            )
        }

        #expect(abs(scale - CanvasTransformReducer.maximumScale) < 0.0001)
}
