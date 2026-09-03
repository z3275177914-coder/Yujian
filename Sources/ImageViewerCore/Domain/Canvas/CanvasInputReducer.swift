import CoreGraphics
import Foundation

/// Pure input normalization for canvas gestures. The view owns event capture;
/// this type keeps the scale curve deterministic and easy to test.
public enum CanvasInputReducer {
    public static let minimumSensitivity: CGFloat = 0.25
    public static let maximumSensitivity: CGFloat = 3
    public static let defaultSensitivity: CGFloat = 1

    private static let discreteWheelStep = CGFloat(log(1.20))
    private static let preciseWheelStep = CGFloat(log(1.01))
    private static let maximumEventStep = CGFloat(log(1.50))

    public static func clampedSensitivity(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else {
            return defaultSensitivity
        }
        return min(maximumSensitivity, max(minimumSensitivity, value))
    }

    /// Returns a multiplicative zoom factor for one scroll event.
    ///
    /// Precise scrolling keeps the device-provided feel and does not apply the
    /// user mouse sensitivity. Discrete wheel input is normalized to one notch
    /// and then mapped exponentially, with a hard per-event limit.
    public static func zoomMultiplier(
        delta: CGFloat,
        isPrecise: Bool,
        sensitivity: CGFloat
    ) -> CGFloat {
        guard delta.isFinite, delta != 0 else {
            return 1
        }

        let logDelta: CGFloat
        if isPrecise {
            logDelta = delta * preciseWheelStep
        } else {
            let direction = delta.sign == .minus ? -CGFloat(1) : CGFloat(1)
            logDelta = direction * discreteWheelStep * clampedSensitivity(sensitivity)
        }

        let boundedLogDelta = min(
            maximumEventStep,
            max(-maximumEventStep, logDelta)
        )
        return CGFloat(exp(Double(boundedLogDelta)))
    }

    /// Converts NSEvent magnification to a stable multiplicative factor.
    public static func magnificationMultiplier(_ magnification: CGFloat) -> CGFloat {
        guard magnification.isFinite, magnification > -1 else {
            return 1
        }

        let boundedMagnification = min(0.5, max(-0.5, magnification))
        return CGFloat(exp(log1p(Double(boundedMagnification))))
    }
}

public enum CanvasViewportReducer {
    /// Calculates a minimap drag target from one fixed gesture origin. The
    /// viewport size never changes during the drag, so refreshed AppKit
    /// snapshots cannot feed back into the pointer delta and make the box
    /// jump or drift.
    public static func draggedCenter(
        for viewport: CGRect,
        from startPoint: CGPoint,
        to currentPoint: CGPoint
    ) -> CGPoint {
        let safeStart = CGPoint(
            x: startPoint.x.isFinite ? startPoint.x : viewport.midX,
            y: startPoint.y.isFinite ? startPoint.y : viewport.midY
        )
        let safeCurrent = CGPoint(
            x: currentPoint.x.isFinite ? currentPoint.x : safeStart.x,
            y: currentPoint.y.isFinite ? currentPoint.y : safeStart.y
        )
        return clampedCenter(
            CGPoint(
                x: viewport.midX + safeCurrent.x - safeStart.x,
                y: viewport.midY + safeCurrent.y - safeStart.y
            ),
            for: viewport
        )
    }

    public static func clampedCenter(
        _ center: CGPoint,
        for viewport: CGRect
    ) -> CGPoint {
        let halfWidth = min(0.5, max(0, viewport.width / 2))
        let halfHeight = min(0.5, max(0, viewport.height / 2))
        let safeCenter = CGPoint(
            x: center.x.isFinite ? center.x : viewport.midX,
            y: center.y.isFinite ? center.y : viewport.midY
        )
        return CGPoint(
            x: min(1 - halfWidth, max(halfWidth, safeCenter.x)),
            y: min(1 - halfHeight, max(halfHeight, safeCenter.y))
        )
    }

    public static func centeredViewport(
        around center: CGPoint,
        size: CGSize
    ) -> CGRect {
        let safeSize = CGSize(
            width: min(1, max(0, size.width.isFinite ? size.width : 0)),
            height: min(1, max(0, size.height.isFinite ? size.height : 0))
        )
        let proposed = CGRect(
            x: center.x - safeSize.width / 2,
            y: center.y - safeSize.height / 2,
            width: safeSize.width,
            height: safeSize.height
        )
        let clamped = clampedCenter(center, for: proposed)
        return CGRect(
            x: clamped.x - safeSize.width / 2,
            y: clamped.y - safeSize.height / 2,
            width: safeSize.width,
            height: safeSize.height
        )
    }
}
