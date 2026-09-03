import AppKit
import Foundation
import ImageViewerCore

/// The minimap is part of the canvas view hierarchy so a pan only changes
/// AppKit layers. Keeping it out of SwiftUI prevents every pointer frame from
/// rebuilding the surrounding inspector and thumbnail sidebar.
final class CanvasMiniMapNSView: NSView {
    static let preferredSize = CGSize(width: 186, height: 134)

    var onViewportCenterChange: ((CGPoint?) -> Void)?

    private let contentInset: CGFloat = 8
    private let previewLayer = CALayer()
    private let viewportLayer = CAShapeLayer()
    private var sourceImage: CGImage?
    private var imageIdentity: ObjectIdentifier?
    private var previewTask: Task<Void, Never>?
    private var viewport: CGRect?
    private var dragStartViewport: CGRect?
    private var dragStartPoint: CGPoint?
    private var lastSentDragCenter: CGPoint?
    private var isDragging = false

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        previewTask?.cancel()
    }

    override func layout() {
        super.layout()
        updateLayerFrames()
        updateViewportLayer()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    func updateContentsScale(_ scale: CGFloat) {
        layer?.contentsScale = scale
        previewLayer.contentsScale = scale
        viewportLayer.contentsScale = scale
    }

    func update(
        image: CGImage,
        viewport: CGRect?
    ) {
        let nextImageIdentity = ObjectIdentifier(image)
        let imageChanged = imageIdentity != nextImageIdentity
        if imageChanged {
            imageIdentity = nextImageIdentity
            sourceImage = image
            // Show the available image immediately. The smaller preview is a
            // later layer-content replacement, never a blank interval.
            previewLayer.contents = image
            previewTask?.cancel()
            previewTask = nil
            resetDragState()

            if max(image.width, image.height) > 640 {
                let expectedIdentity = nextImageIdentity
                previewTask = Task { [weak self] in
                    let preparedImage = await Task.detached(priority: .utility) {
                        makeCanvasMiniMapPreviewImage(from: image)
                    }.value
                    guard !Task.isCancelled else {
                        return
                    }
                    await MainActor.run {
                        guard let self,
                              self.imageIdentity == expectedIdentity else {
                            return
                        }
                        self.previewLayer.contents = preparedImage
                        self.previewTask = nil
                    }
                }
            }
        }

        self.viewport = normalizedViewport(viewport)
        if imageChanged {
            updateLayerFrames()
        }
        updateViewportLayer()
    }

    override func mouseDown(with event: NSEvent) {
        guard let viewport,
              let sourceImage,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let contentRect = imageContentRect(in: bounds, image: sourceImage)
        guard contentRect.contains(point) else {
            return
        }

        let startPoint = normalizedPoint(point, in: contentRect)
        let displayedViewport = CanvasViewportReducer.centeredViewport(
            around: CGPoint(x: viewport.midX, y: viewport.midY),
            size: viewport.size
        )
        let minimumHitSize = CGSize(
            width: min(1, max(displayedViewport.width, 12 / max(contentRect.width, 1))),
            height: min(1, max(displayedViewport.height, 12 / max(contentRect.height, 1)))
        )
        let hitViewport = CanvasViewportReducer.centeredViewport(
            around: CGPoint(x: displayedViewport.midX, y: displayedViewport.midY),
            size: minimumHitSize
        )
        let requestedCenter = hitViewport.contains(startPoint)
            ? CGPoint(x: displayedViewport.midX, y: displayedViewport.midY)
            : startPoint
        // The main canvas may constrain the requested center at an image edge.
        // Store the same clamped viewport that the canvas is expected to show,
        // so the first drag delta cannot introduce a one-frame jump.
        let initialViewport = CanvasViewportReducer.centeredViewport(
            around: requestedCenter,
            size: displayedViewport.size
        )
        let initialCenter = CGPoint(
            x: initialViewport.midX,
            y: initialViewport.midY
        )

        dragStartViewport = initialViewport
        dragStartPoint = startPoint
        lastSentDragCenter = nil
        isDragging = true
        sendCenterIfNeeded(initialCenter)
        updateViewportLayer()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartViewport,
              let dragStartPoint,
              let sourceImage,
              isDragging else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let contentRect = imageContentRect(in: bounds, image: sourceImage)
        guard contentRect.width > 0, contentRect.height > 0 else {
            return
        }

        let target = CanvasViewportReducer.draggedCenter(
            for: dragStartViewport,
            from: dragStartPoint,
            to: normalizedPoint(point, in: contentRect)
        )
        sendCenterIfNeeded(target)
        updateViewportLayer()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else {
            return
        }

        // AppKit is not required to deliver a final `mouseDragged` event at
        // the exact release location. Submit that location once more so the
        // final minimap position and the canvas transform cannot differ by a
        // few pixels.
        if let dragStartViewport,
           let dragStartPoint,
           let sourceImage {
            let point = convert(event.locationInWindow, from: nil)
            let contentRect = imageContentRect(in: bounds, image: sourceImage)
            if contentRect.width > 0, contentRect.height > 0 {
                let target = CanvasViewportReducer.draggedCenter(
                    for: dragStartViewport,
                    from: dragStartPoint,
                    to: normalizedPoint(point, in: contentRect)
                )
                sendCenterIfNeeded(target)
            }
        }

        isDragging = false
        dragStartViewport = nil
        dragStartPoint = nil
        lastSentDragCenter = nil
        updateViewportLayer()
    }

    private func configure() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.96)
            .cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.isGeometryFlipped = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(0.7)
            .cgColor

        previewLayer.contentsGravity = .resize
        previewLayer.magnificationFilter = .linear
        previewLayer.minificationFilter = .trilinear
        previewLayer.isGeometryFlipped = true
        layer?.addSublayer(previewLayer)

        viewportLayer.fillColor = NSColor.controlAccentColor
            .withAlphaComponent(0.16)
            .cgColor
        viewportLayer.strokeColor = NSColor.controlAccentColor.cgColor
        viewportLayer.lineWidth = 2
        viewportLayer.lineJoin = .round
        layer?.addSublayer(viewportLayer)

        setAccessibilityIdentifier("canvas-minimap")
        setAccessibilityLabel("画布缩略图和视口选框")
        toolTip = "拖动视口选框移动图片"
    }

    private func updateLayerFrames() {
        let contentBounds = bounds.insetBy(dx: contentInset, dy: contentInset)
        let contentRect = imageContentRect(in: contentBounds, image: sourceImage)
        previewLayer.frame = contentRect
        viewportLayer.frame = bounds
    }

    private func updateViewportLayer() {
        guard let viewport, let sourceImage else {
            viewportLayer.path = nil
            return
        }
        let contentBounds = bounds.insetBy(dx: contentInset, dy: contentInset)
        let contentRect = imageContentRect(in: contentBounds, image: sourceImage)
        guard contentRect.width > 0, contentRect.height > 0 else {
            viewportLayer.path = nil
            return
        }

        // `viewport` is the canonical value returned by the canvas transform.
        // Never draw a stale gesture-only center here: after a minimap click,
        // the main canvas can be constrained at an edge or continue moving
        // under a second gesture.
        let displayedViewport = viewport
        let width = min(
            contentRect.width,
            max(4, displayedViewport.width * contentRect.width)
        )
        let height = min(
            contentRect.height,
            max(4, displayedViewport.height * contentRect.height)
        )
        let rect = CGRect(
            x: min(
                contentRect.maxX - width,
                max(
                    contentRect.minX,
                    contentRect.minX + displayedViewport.midX * contentRect.width - width / 2
                )
            ),
            y: min(
                contentRect.maxY - height,
                max(
                    contentRect.minY,
                    contentRect.minY + displayedViewport.midY * contentRect.height - height / 2
                )
            ),
            width: width,
            height: height
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        viewportLayer.path = CGPath(rect: rect, transform: nil)
        CATransaction.commit()
    }

    private func sendCenterIfNeeded(_ center: CGPoint) {
        guard lastSentDragCenter == nil
                || !centersAreClose(lastSentDragCenter!, center) else {
            return
        }
        lastSentDragCenter = center
        onViewportCenterChange?(center)
    }

    private func resetDragState() {
        isDragging = false
        dragStartViewport = nil
        dragStartPoint = nil
        lastSentDragCenter = nil
    }

    private func imageContentRect(in rect: CGRect, image: CGImage?) -> CGRect {
        guard let image,
              rect.width > 0,
              rect.height > 0,
              image.height > 0 else {
            return .zero
        }

        let imageAspect = CGFloat(image.width) / CGFloat(image.height)
        let containerAspect = rect.width / rect.height
        if imageAspect > containerAspect {
            let height = rect.width / imageAspect
            return CGRect(
                x: rect.minX,
                y: rect.minY + (rect.height - height) / 2,
                width: rect.width,
                height: height
            )
        }

        let width = rect.height * imageAspect
        return CGRect(
            x: rect.minX + (rect.width - width) / 2,
            y: rect.minY,
            width: width,
            height: rect.height
        )
    }

    private func normalizedPoint(_ point: CGPoint, in contentRect: CGRect) -> CGPoint {
        CGPoint(
            x: min(1, max(0, (point.x - contentRect.minX) / max(contentRect.width, 1))),
            y: min(1, max(0, (point.y - contentRect.minY) / max(contentRect.height, 1)))
        )
    }

    private func normalizedViewport(_ rect: CGRect?) -> CGRect? {
        guard let rect,
              rect.minX.isFinite,
              rect.minY.isFinite,
              rect.width.isFinite,
              rect.height.isFinite else {
            return nil
        }

        let size = CGSize(
            width: min(1, max(0.01, rect.width)),
            height: min(1, max(0.01, rect.height))
        )
        return CanvasViewportReducer.centeredViewport(
            around: CanvasViewportReducer.clampedCenter(
                CGPoint(x: rect.midX, y: rect.midY),
                for: CGRect(origin: .zero, size: size)
            ),
            size: size
        )
    }

    private func centersAreClose(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 0.0005 && abs(lhs.y - rhs.y) < 0.0005
    }
}

private func makeCanvasMiniMapPreviewImage(
    from image: CGImage,
    maxPixelSize: Int = 640
) -> CGImage {
    let longestSide = max(image.width, image.height)
    guard longestSide > maxPixelSize,
          image.width > 0,
          image.height > 0 else {
        return image
    }

    let scale = CGFloat(maxPixelSize) / CGFloat(longestSide)
    let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
    let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        return image
    }

    context.interpolationQuality = .medium
    context.draw(
        image,
        in: CGRect(x: 0, y: 0, width: width, height: height)
    )
    return context.makeImage() ?? image
}
