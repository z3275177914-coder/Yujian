import CoreGraphics
import Foundation

public enum CanvasDisplayMode: String, CaseIterable, Equatable, Identifiable, Sendable {
    case fit = "适应窗口"
    case infinite = "无限画布"
    case actualSize = "实际大小"

    public var id: String { rawValue }
}

public struct CanvasTransformState: Equatable, Sendable {
    public var mode: CanvasDisplayMode
    public var scale: CGFloat
    public var translation: CGPoint
    public var viewportSize: CGSize
    public var imagePixelSize: CGSize
    public var rotationDegrees: Double
    public var isFlippedHorizontally: Bool

    public init(
        mode: CanvasDisplayMode = .fit,
        scale: CGFloat = 1,
        translation: CGPoint = .zero,
        viewportSize: CGSize = .zero,
        imagePixelSize: CGSize = .zero,
        rotationDegrees: Double = 0,
        isFlippedHorizontally: Bool = false
    ) {
        self.mode = mode
        self.scale = CanvasTransformReducer.clampedScale(scale)
        self.translation = translation
        self.viewportSize = viewportSize
        self.imagePixelSize = imagePixelSize
        self.rotationDegrees = rotationDegrees.isFinite ? rotationDegrees : 0
        self.isFlippedHorizontally = isFlippedHorizontally
    }
}

public enum CanvasTransformCommand: Equatable, Sendable {
    case setMode(CanvasDisplayMode)
    case setScale(CGFloat, anchor: CGPoint?)
    case setTranslation(CGPoint)
    case pan(by: CGPoint)
    case moveViewport(center: CGPoint)
    case setViewportSize(CGSize)
    case setImagePixelSize(CGSize)
    case setRotation(Double)
    case setFlipHorizontally(Bool)
    case reset
}

public enum CanvasTransformReducer {
    public static let minimumScale: CGFloat = 0.05
    public static let maximumScale: CGFloat = 20

    public static func reduce(
        _ state: CanvasTransformState,
        _ command: CanvasTransformCommand
    ) -> CanvasTransformState {
        var next = state

        switch command {
        case let .setMode(mode):
            next.mode = mode
            next.scale = 1
            next.translation = .zero

        case let .setScale(value, anchor):
            next = stateAfterScaling(state, to: value, around: anchor)

        case let .setTranslation(translation):
            next.translation = constrainedTranslation(for: state, proposed: translation)

        case let .pan(delta):
            next.translation = constrainedTranslation(
                for: state,
                proposed: CGPoint(
                    x: state.translation.x + delta.x,
                    y: state.translation.y + delta.y
                )
            )

        case let .moveViewport(center):
            next.translation = translation(forViewportCenter: center, in: state)

        case let .setViewportSize(size):
            next.viewportSize = sanitizedSize(size)
            next.translation = constrainedTranslation(for: next, proposed: state.translation)

        case let .setImagePixelSize(size):
            next.imagePixelSize = sanitizedSize(size)
            next.translation = .zero

        case let .setRotation(degrees):
            next.rotationDegrees = degrees.isFinite ? degrees : 0
            next.translation = constrainedTranslation(for: next, proposed: state.translation)

        case let .setFlipHorizontally(isFlipped):
            next.isFlippedHorizontally = isFlipped
            next.translation = constrainedTranslation(for: next, proposed: state.translation)

        case .reset:
            next.scale = 1
            next.translation = .zero
            next.rotationDegrees = 0
            next.isFlippedHorizontally = false
            next.mode = .fit
        }

        next.scale = clampedScale(next.scale)
        return next
    }

    public static func clampedScale(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else {
            return 1
        }
        return min(maximumScale, max(minimumScale, value))
    }

    public static func baseScale(for state: CanvasTransformState) -> CGFloat {
        guard state.imagePixelSize.width > 0,
              state.imagePixelSize.height > 0,
              state.viewportSize.width > 0,
              state.viewportSize.height > 0 else {
            return 1
        }
        guard state.mode != .actualSize else {
            return 1
        }

        let rotatedSize = rotatedImageSize(for: state)
        return max(
            0.01,
            min(
                state.viewportSize.width / max(rotatedSize.width, 1),
                state.viewportSize.height / max(rotatedSize.height, 1)
            )
        )
    }

    public static func effectiveScale(for state: CanvasTransformState) -> CGFloat {
        baseScale(for: state) * clampedScale(state.scale)
    }

    public static func rotatedImageSize(for state: CanvasTransformState) -> CGSize {
        let radians = abs(state.rotationDegrees * .pi / 180)
        let width = abs(CGFloat(cos(radians))) * state.imagePixelSize.width
            + abs(CGFloat(sin(radians))) * state.imagePixelSize.height
        let height = abs(CGFloat(sin(radians))) * state.imagePixelSize.width
            + abs(CGFloat(cos(radians))) * state.imagePixelSize.height
        return CGSize(width: width, height: height)
    }

    public static func transformedImageSize(for state: CanvasTransformState) -> CGSize {
        let size = rotatedImageSize(for: state)
        let scale = effectiveScale(for: state)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    public static func constrainedTranslation(
        for state: CanvasTransformState,
        proposed: CGPoint
    ) -> CGPoint {
        guard state.mode != .infinite,
              state.viewportSize.width > 0,
              state.viewportSize.height > 0 else {
            return proposed
        }

        let contentSize = transformedImageSize(for: state)
        return CGPoint(
            x: constrainedAxis(
                proposed.x,
                contentLength: contentSize.width,
                viewportLength: state.viewportSize.width
            ),
            y: constrainedAxis(
                proposed.y,
                contentLength: contentSize.height,
                viewportLength: state.viewportSize.height
            )
        )
    }

    public static func viewPoint(
        forImagePoint imagePoint: CGPoint,
        in state: CanvasTransformState
    ) -> CGPoint {
        let center = CGPoint(
            x: state.viewportSize.width / 2 + state.translation.x,
            y: state.viewportSize.height / 2 + state.translation.y
        )
        let transformedPoint = imagePoint.applying(contentTransform(for: state))
        return CGPoint(x: center.x + transformedPoint.x, y: center.y + transformedPoint.y)
    }

    public static func imagePoint(
        forViewPoint viewPoint: CGPoint,
        in state: CanvasTransformState
    ) -> CGPoint? {
        let transform = viewTransform(for: state)
        guard !transform.isIdentity || state.imagePixelSize != .zero else {
            return nil
        }
        return viewPoint.applying(transform.inverted())
    }

    /// Returns the visible image rectangle in normalized image coordinates.
    /// Keeping this calculation beside the transform reducer makes the main
    /// canvas and minimap use the same translation, scale, rotation and edge
    /// clamping rules.
    public static func normalizedViewport(
        for state: CanvasTransformState
    ) -> CGRect? {
        guard state.imagePixelSize.width > 0,
              state.imagePixelSize.height > 0,
              state.viewportSize.width > 0,
              state.viewportSize.height > 0 else {
            return nil
        }

        let inverse = viewTransform(for: state).inverted()
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: state.viewportSize.width, y: 0),
            CGPoint(x: state.viewportSize.width, y: state.viewportSize.height),
            CGPoint(x: 0, y: state.viewportSize.height)
        ].map { $0.applying(inverse) }
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return nil
        }

        let xValues = corners.map(\.x)
        let yValues = corners.map(\.y)
        let imageBounds = CGRect(
            x: -state.imagePixelSize.width / 2,
            y: -state.imagePixelSize.height / 2,
            width: state.imagePixelSize.width,
            height: state.imagePixelSize.height
        )
        let visibleBounds = CGRect(
            x: xValues.min() ?? 0,
            y: yValues.min() ?? 0,
            width: (xValues.max() ?? 0) - (xValues.min() ?? 0),
            height: (yValues.max() ?? 0) - (yValues.min() ?? 0)
        )
        guard visibleBounds.width > 0, visibleBounds.height > 0 else {
            return nil
        }

        let size = CGSize(
            width: min(1, max(0.01, visibleBounds.width / imageBounds.width)),
            height: min(1, max(0.01, visibleBounds.height / imageBounds.height))
        )
        let center = CGPoint(
            x: (visibleBounds.midX - imageBounds.minX) / imageBounds.width,
            y: (visibleBounds.midY - imageBounds.minY) / imageBounds.height
        )
        return CanvasViewportReducer.centeredViewport(
            around: CanvasViewportReducer.clampedCenter(
                center,
                for: CGRect(origin: .zero, size: size)
            ),
            size: size
        )
    }

    public static func contentTransform(
        for state: CanvasTransformState
    ) -> CGAffineTransform {
        let scale = effectiveScale(for: state)
        let radians = state.rotationDegrees * .pi / 180
        return CGAffineTransform.identity
            .rotated(by: radians)
            .scaledBy(
                x: state.isFlippedHorizontally ? -scale : scale,
                y: scale
            )
    }

    public static func viewTransform(
        for state: CanvasTransformState
    ) -> CGAffineTransform {
        // CALayer receives the content transform and position separately:
        // source point -> rotate/scale/flip -> translate to the canvas
        // center. Concatenating in this order keeps inverse mapping (used by
        // minimap and pointer hit testing) identical to viewPoint(for:in:).
        contentTransform(for: state).concatenating(
            CGAffineTransform(
                translationX: state.viewportSize.width / 2 + state.translation.x,
                y: state.viewportSize.height / 2 + state.translation.y
            )
        )
    }

    private static func stateAfterScaling(
        _ state: CanvasTransformState,
        to value: CGFloat,
        around anchor: CGPoint?
    ) -> CanvasTransformState {
        var next = state
        let oldEffectiveScale = effectiveScale(for: state)
        next.scale = clampedScale(value)
        let newEffectiveScale = effectiveScale(for: next)

        guard let anchor,
              oldEffectiveScale > 0,
              newEffectiveScale > 0,
              state.viewportSize.width > 0,
              state.viewportSize.height > 0 else {
            next.translation = constrainedTranslation(for: next, proposed: state.translation)
            return next
        }

        let viewportCenter = CGPoint(
            x: state.viewportSize.width / 2,
            y: state.viewportSize.height / 2
        )
        let vector = CGPoint(
            x: anchor.x - viewportCenter.x - state.translation.x,
            y: anchor.y - viewportCenter.y - state.translation.y
        )
        let ratio = newEffectiveScale / oldEffectiveScale
        next.translation = CGPoint(
            x: anchor.x - viewportCenter.x - vector.x * ratio,
            y: anchor.y - viewportCenter.y - vector.y * ratio
        )
        next.translation = constrainedTranslation(for: next, proposed: next.translation)
        return next
    }

    private static func translation(
        forViewportCenter normalizedCenter: CGPoint,
        in state: CanvasTransformState
    ) -> CGPoint {
        guard state.imagePixelSize.width > 0,
              state.imagePixelSize.height > 0 else {
            return state.translation
        }

        let clampedCenter = CGPoint(
            x: min(1, max(0, normalizedCenter.x)),
            y: min(1, max(0, normalizedCenter.y))
        )
        let imagePoint = CGPoint(
            x: (clampedCenter.x - 0.5) * state.imagePixelSize.width,
            y: (clampedCenter.y - 0.5) * state.imagePixelSize.height
        )
        let transformedPoint = imagePoint.applying(contentTransform(for: state))
        return constrainedTranslation(
            for: state,
            proposed: CGPoint(x: -transformedPoint.x, y: -transformedPoint.y)
        )
    }

    private static func constrainedAxis(
        _ proposed: CGFloat,
        contentLength: CGFloat,
        viewportLength: CGFloat
    ) -> CGFloat {
        let overflow = (contentLength - viewportLength) / 2
        guard overflow > 0 else {
            return 0
        }
        return min(overflow, max(-overflow, proposed))
    }

    private static func sanitizedSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width.isFinite ? max(0, size.width) : 0,
            height: size.height.isFinite ? max(0, size.height) : 0
        )
    }
}
