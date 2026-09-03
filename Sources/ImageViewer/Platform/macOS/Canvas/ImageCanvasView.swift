import AppKit
import ImageViewerCore
import SwiftUI

enum CanvasKeyAction {
    case previous
    case next
    case toggleDisplayMode
    case zoomIn
    case zoomOut
    case fit
    case infinite
    case actualSize
    case rotate
    case inspector
    case fullscreen
    case trash
}

struct ImageCanvasView: NSViewRepresentable {
    let image: CGImage?
    let sourceURL: URL?
    let sourcePixelSize: CGSize?
    let animatedFrameStore: AnimatedFrameStore?
    let motionPhoto: MotionPhotoInfo?
    @Binding var displayMode: CanvasDisplayMode
    @Binding var zoomFactor: CGFloat
    let mouseSensitivity: CGFloat
    let rotationDegrees: Double
    let isFlippedHorizontally: Bool
    let shortcuts: ShortcutConfiguration
    let isSelectionMode: Bool
    let selection: CGRect?
    let isCropSelectionMode: Bool
    let cropSelection: CGRect?
    let onKeyAction: (CanvasKeyAction) -> Void
    let onDisplayModeChange: (CanvasDisplayMode) -> Void
    let onZoomChange: (CGFloat) -> Void
    let onSelectionChange: (CGRect?) -> Void
    let onCropSelectionChange: (CGRect?) -> Void
    let onPixelSampleChange: (CGPoint?) -> Void

    func makeNSView(context: Context) -> ImageCanvasNSView {
        let view = ImageCanvasNSView()
        view.onKeyAction = onKeyAction
        view.onDisplayModeChange = onDisplayModeChange
        view.onZoomChange = onZoomChange
        view.onSelectionChange = onSelectionChange
        view.onCropSelectionChange = onCropSelectionChange
        view.onPixelSampleChange = onPixelSampleChange
        view.updateImageSource(url: sourceURL, pixelSize: sourcePixelSize)
        view.image = image
        view.updateAnimatedFrameStore(animatedFrameStore)
        view.updateMotionPhoto(motionPhoto)
        view.synchronizeModelState(
            displayMode: displayMode,
            zoomFactor: zoomFactor,
            rotationDegrees: rotationDegrees,
            isFlippedHorizontally: isFlippedHorizontally
        )
        view.shortcuts = shortcuts
        view.isSelectionMode = isSelectionMode
        view.selection = selection
        view.isCropSelectionMode = isCropSelectionMode
        view.cropSelection = cropSelection
        view.mouseSensitivity = mouseSensitivity
        return view
    }

    func updateNSView(_ nsView: ImageCanvasNSView, context: Context) {
        nsView.onKeyAction = onKeyAction
        nsView.onDisplayModeChange = onDisplayModeChange
        nsView.onZoomChange = onZoomChange
        nsView.onSelectionChange = onSelectionChange
        nsView.onCropSelectionChange = onCropSelectionChange
        nsView.onPixelSampleChange = onPixelSampleChange
        nsView.updateImageSource(url: sourceURL, pixelSize: sourcePixelSize)
        nsView.image = image
        nsView.updateAnimatedFrameStore(animatedFrameStore)
        nsView.updateMotionPhoto(motionPhoto)
        nsView.synchronizeModelState(
            displayMode: displayMode,
            zoomFactor: zoomFactor,
            rotationDegrees: rotationDegrees,
            isFlippedHorizontally: isFlippedHorizontally
        )
        nsView.shortcuts = shortcuts
        nsView.isSelectionMode = isSelectionMode
        nsView.selection = selection
        nsView.isCropSelectionMode = isCropSelectionMode
        nsView.cropSelection = cropSelection
        nsView.mouseSensitivity = mouseSensitivity
    }
}

final class ImageCanvasNSView: NSView {
    private struct InteractiveGeometryKey: Equatable {
        let mode: CanvasDisplayMode
        let scale: CGFloat
        let viewportSize: CGSize
        let imagePixelSize: CGSize
        let rotationDegrees: Double
        let isFlippedHorizontally: Bool

        init(state: CanvasTransformState) {
            mode = state.mode
            scale = state.scale
            viewportSize = state.viewportSize
            imagePixelSize = state.imagePixelSize
            rotationDegrees = state.rotationDegrees
            isFlippedHorizontally = state.isFlippedHorizontally
        }
    }

    var image: CGImage? {
        didSet {
            let imageChanged: Bool
            switch (image, oldValue) {
            case (nil, nil):
                imageChanged = false
            case let (newImage?, oldImage?):
                imageChanged = newImage !== oldImage
            default:
                imageChanged = true
            }
            if imageChanged {
                if motionPhotoPlaybackController.hasMotionPhoto {
                    cancelPendingMotionPhotoClick()
                    motionPhotoPlaybackController.stopPlayback()
                }
                cancelSettledRendering()
                renderQualityState.reset()
                applySampling(for: .settled)
                let imageSize = CGSize(
                    width: logicalImageSize.width,
                    height: logicalImageSize.height
                )
                if imageSize != transformState.imagePixelSize {
                    transformState = CanvasTransformReducer.reduce(
                        transformState,
                        .setImagePixelSize(imageSize)
                    )
                } else {
                    transformState.imagePixelSize = imageSize
                }
                cancelZoomCommit()
                invalidateDetailProvider()
                setDisplayedImage(image)
                imageLayer.bounds = CGRect(
                    x: 0,
                    y: 0,
                    width: logicalImageSize.width,
                    height: logicalImageSize.height
                )
                imageLayer.isHidden = image == nil
                updateImageLayer()
            }
        }
    }

    private var sourceURL: URL?
    private var sourcePixelSize = CGSize.zero

    func updateImageSource(url: URL?, pixelSize: CGSize?) {
        let normalizedSize: CGSize
        if let pixelSize,
           pixelSize.width.isFinite,
           pixelSize.height.isFinite,
           pixelSize.width > 0,
           pixelSize.height > 0 {
            normalizedSize = pixelSize
        } else {
            normalizedSize = .zero
        }

        guard sourceURL != url || sourcePixelSize != normalizedSize else {
            return
        }
        sourceURL = url
        sourcePixelSize = normalizedSize
        invalidateDetailProvider()

        guard let image, image.width > 0, image.height > 0 else {
            return
        }
        let imageSize = logicalImageSize
        transformState = CanvasTransformReducer.reduce(
            transformState,
            .setImagePixelSize(imageSize)
        )
        imageLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: imageSize.width,
            height: imageSize.height
        )
        updateImageLayer()
    }

    func updateAnimatedFrameStore(_ store: AnimatedFrameStore?) {
        let isSameStore: Bool
        switch (store, animatedFrameStore) {
        case (nil, nil):
            isSameStore = true
        case let (next?, current?):
            isSameStore = next === current
        default:
            isSameStore = false
        }
        guard !isSameStore else {
            return
        }

        if let animatedFrameStore,
           let animatedFrameObserverToken {
            animatedFrameStore.removeObserver(animatedFrameObserverToken)
        }
        animatedFrameObserverToken = nil
        animatedFrameStore = store

        guard let store else {
            return
        }
        animatedFrameObserverToken = store.addObserver { [weak self] frame in
            self?.displayAnimatedFrame(frame)
        }
    }

    func updateMotionPhoto(_ info: MotionPhotoInfo?) {
        let infoChanged = motionPhotoPlaybackController.info != info
        if info == nil {
            cancelPendingMotionPhotoClick()
        }
        motionPhotoPlaybackController.update(info: info)
        if infoChanged {
            updateImageLayer()
        }
    }

    var displayMode: CanvasDisplayMode {
        get { transformState.mode }
        set { synchronizeDisplayModeFromModel(newValue) }
    }

    var zoomFactor: CGFloat {
        get { transformState.scale }
        set { synchronizeZoomFactorFromModel(newValue) }
    }

    var mouseSensitivity: CGFloat = 1

    var rotationDegrees: Double {
        get { transformState.rotationDegrees }
        set {
            applyTransformCommand(.setRotation(newValue))
        }
    }

    var isFlippedHorizontally: Bool {
        get { transformState.isFlippedHorizontally }
        set {
            applyTransformCommand(.setFlipHorizontally(newValue))
        }
    }

    var shortcuts = ShortcutConfiguration.defaults

    var isSelectionMode = false {
        didSet {
            if !isSelectionMode {
                selectionStartPoint = nil
                selectionPreview = nil
            }
            updateSelectionLayer()
        }
    }

    var isCropSelectionMode = false {
        didSet {
            if !isCropSelectionMode {
                selectionStartPoint = nil
                selectionPreview = nil
            }
            updateSelectionLayer()
        }
    }

    var selection: CGRect? {
        didSet {
            updateSelectionLayer()
        }
    }

    var cropSelection: CGRect? {
        didSet {
            updateSelectionLayer()
        }
    }

    var onKeyAction: ((CanvasKeyAction) -> Void)?
    var onDisplayModeChange: ((CanvasDisplayMode) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)?
    var onSelectionChange: ((CGRect?) -> Void)?
    var onCropSelectionChange: ((CGRect?) -> Void)?
    var onPixelSampleChange: ((CGPoint?) -> Void)?

    private let imageLayer = CALayer()
    private let motionPhotoPlaybackController = MotionPhotoPlaybackController()
    private let selectionLayer = CAShapeLayer()
    private let minimapView = CanvasMiniMapNSView()
    private var animatedFrameStore: AnimatedFrameStore?
    private var animatedFrameObserverToken: UUID?
    private var transformState = CanvasTransformState()
    private var dragStartPoint: CGPoint?
    private var panStartTranslation = CGPoint.zero
    private var selectionStartPoint: CGPoint?
    private var selectionPreview: CGRect?
    private var renderQualityState = CanvasRenderQualityState()
    private var settledRenderTimer: DispatchSourceTimer?
    private var interactiveOverlayTimer: DispatchSourceTimer?
    private var pendingNativeZoom: CGFloat?
    private var zoomCommitTimer: DispatchSourceTimer?
    private var lastModelZoomFactor: CGFloat = 1
    private var detailProvider: ImageTileProvider?
    private var detailDescriptor: ImageTileDescriptor?
    private var detailProviderImageID: ObjectIdentifier?
    private var displayedImage: CGImage?
    private var interactiveGeometryKey: InteractiveGeometryKey?
    private var interactiveContentTransform = CGAffineTransform.identity
    private var interactiveTranslationOverflow = CGSize.zero
    private var isPanning = false
    private var lastPixelSampleTimestamp = -Double.greatestFiniteMagnitude
    private var pointerDownPoint: CGPoint?
    private var maximumPointerTravel: CGFloat = 0
    private var pendingMotionPhotoClick: DispatchWorkItem?

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    deinit {
        settledRenderTimer?.setEventHandler {}
        settledRenderTimer?.cancel()
        interactiveOverlayTimer?.setEventHandler {}
        interactiveOverlayTimer?.cancel()
        zoomCommitTimer?.setEventHandler {}
        zoomCommitTimer?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateContentsScale()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelPendingMotionPhotoClick()
            motionPhotoPlaybackController.stopPlayback()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCanvasBackground()
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
        selectionLayer.frame = bounds
        let previousViewportSize = transformState.viewportSize
        transformState = CanvasTransformReducer.reduce(
            transformState,
            .setViewportSize(bounds.size)
        )
        layoutMiniMap()
        // A layout pass is also generated when an ancestor is diffed. Avoid
        // reconfiguring the tile provider when the canvas viewport did not
        // actually change; this is especially important while a workbench is
        // being scrolled or its toolbar is replaced.
        if previousViewportSize != bounds.size {
            updateImageLayer()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        cancelPendingMotionPhotoClick()

        if isSelectionMode || isCropSelectionMode {
            selectionStartPoint = point
            selectionPreview = nil
            updateSelectionLayer()
            return
        }

        if event.clickCount == 2 {
            pointerDownPoint = nil
            maximumPointerTravel = 0
            let nextMode: CanvasDisplayMode = displayMode == .fit ? .actualSize : .fit
            cancelZoomCommit()
            applyTransformCommand(.setMode(nextMode))
            onDisplayModeChange?(nextMode)
            return
        }

        pointerDownPoint = point
        maximumPointerTravel = 0
        dragStartPoint = point
        panStartTranslation = transformState.translation
        isPanning = true
        beginInteractiveRendering()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !isPanning,
              renderQualityState.phase != .interactive else {
            return
        }
        let timestamp = event.timestamp.isFinite
            ? event.timestamp
            : CACurrentMediaTime()
        guard timestamp - lastPixelSampleTimestamp >= 1.0 / 30.0 else {
            return
        }
        lastPixelSampleTimestamp = timestamp
        let point = convert(event.locationInWindow, from: nil)
        onPixelSampleChange?(normalizedImagePoint(from: point))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let pointerDownPoint {
            let travel = hypot(
                point.x - pointerDownPoint.x,
                point.y - pointerDownPoint.y
            )
            maximumPointerTravel = max(maximumPointerTravel, travel)
            if maximumPointerTravel > MotionPhotoClickReducer.movementThreshold {
                cancelPendingMotionPhotoClick()
            }
        }

        if let selectionStartPoint {
            selectionPreview = normalizedSelection(
                from: selectionStartPoint,
                to: point
            )
            updateSelectionLayer()
            return
        }

        guard let dragStartPoint else {
            return
        }
        let proposedTranslation = CGPoint(
            x: panStartTranslation.x + point.x - dragStartPoint.x,
            y: panStartTranslation.y + point.y - dragStartPoint.y
        )
        applyInteractiveTransformCommand(.setTranslation(proposedTranslation))
    }

    override func mouseUp(with event: NSEvent) {
        if selectionStartPoint != nil {
            let point = convert(event.locationInWindow, from: nil)
            let finalSelection = normalizedSelection(
                from: selectionStartPoint ?? point,
                to: point
            )
            selection = finalSelection
            selectionStartPoint = nil
            selectionPreview = nil
            updateSelectionLayer()
            if isCropSelectionMode {
                onCropSelectionChange?(finalSelection)
            } else {
                onSelectionChange?(finalSelection)
            }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let isClick = MotionPhotoClickReducer.isSingleClick(
            clickCount: event.clickCount,
            maximumTravel: pointerDownPoint == nil
                ? .greatestFiniteMagnitude
                : maximumPointerTravel,
            isEnabled: motionPhotoPlaybackController.hasMotionPhoto,
            isInsideContent: normalizedImagePoint(from: point) != nil
        )
        dragStartPoint = nil
        pointerDownPoint = nil
        maximumPointerTravel = 0
        isPanning = false
        scheduleSettledRendering()
        if isClick {
            scheduleMotionPhotoPlayback()
        }
        onPixelSampleChange?(normalizedImagePoint(from: point))
    }

    override func magnify(with event: NSEvent) {
        cancelPendingMotionPhotoClick()
        let anchor = convert(event.locationInWindow, from: nil)
        setZoom(
            zoomFactor * CanvasInputReducer.magnificationMultiplier(event.magnification),
            around: anchor
        )
    }

    override func scrollWheel(with event: NSEvent) {
        cancelPendingMotionPhotoClick()
        let delta = event.scrollingDeltaY
        guard delta != 0 else {
            return
        }
        let anchor = convert(event.locationInWindow, from: nil)
        let multiplier = CanvasInputReducer.zoomMultiplier(
            delta: delta,
            isPrecise: event.hasPreciseScrollingDeltas,
            sensitivity: effectiveMouseSensitivity
        )
        setZoom(zoomFactor * multiplier, around: anchor)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 {
            onKeyAction?(.previous)
            return
        }
        if event.keyCode == 124 {
            onKeyAction?(.next)
            return
        }
        if event.keyCode == 51 {
            onKeyAction?(.trash)
            return
        }

        guard let key = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }

        if key == shortcuts.previous {
            onKeyAction?(.previous)
        } else if key == shortcuts.next {
            onKeyAction?(.next)
        } else if key == " " {
            if motionPhotoPlaybackController.hasMotionPhoto {
                motionPhotoPlaybackController.togglePlayback()
            } else {
                onKeyAction?(.toggleDisplayMode)
            }
        } else if key == "+" || key == "=" {
            onKeyAction?(.zoomIn)
        } else if key == "-" {
            onKeyAction?(.zoomOut)
        } else if key == "0" {
            onKeyAction?(.fit)
        } else if key == "1" {
            onKeyAction?(.actualSize)
        } else if key == "2" {
            onKeyAction?(.infinite)
        } else if key == shortcuts.rotate {
            onKeyAction?(.rotate)
        } else if key == shortcuts.inspector {
            onKeyAction?(.inspector)
        } else if key == shortcuts.fullscreen {
            onKeyAction?(.fullscreen)
        } else {
            super.keyDown(with: event)
        }
    }

    private func configureLayers() {
        wantsLayer = true
        layer = CALayer()
        updateCanvasBackground()
        layer?.masksToBounds = true
        layer?.isGeometryFlipped = true

        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.allowsEdgeAntialiasing = false
        imageLayer.isGeometryFlipped = true
        layer?.addSublayer(imageLayer)

        let motionPhotoLayer = motionPhotoPlaybackController.layer
        motionPhotoLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        motionPhotoLayer.isGeometryFlipped = true
        motionPhotoLayer.isHidden = true
        motionPhotoPlaybackController.onPlaybackVisibilityChange = { [weak self] isVisible in
            self?.setMotionPhotoPlaybackVisible(isVisible)
        }
        layer?.addSublayer(motionPhotoLayer)
        applySampling(for: .settled)

        selectionLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        selectionLayer.strokeColor = NSColor.systemBlue.cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineJoin = .round
        selectionLayer.isHidden = true
        layer?.addSublayer(selectionLayer)

        minimapView.onViewportCenterChange = { [weak self] center in
            guard let self, let center else {
                return
            }
            self.moveViewport(to: center)
        }
        minimapView.isHidden = true
        addSubview(minimapView)

        updateContentsScale()
    }

    private func updateCanvasBackground() {
        let color: NSColor
        switch displayMode {
        case .infinite:
            color = NSColor.windowBackgroundColor
        case .fit, .actualSize:
            color = NSColor(calibratedWhite: 0.10, alpha: 1)
        }
        layer?.backgroundColor = color.cgColor
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        imageLayer.contentsScale = 1
        motionPhotoPlaybackController.layer.contentsScale = scale
        selectionLayer.contentsScale = scale
        minimapView.updateContentsScale(scale)
    }

    private func layoutMiniMap() {
        let preferredSize = CanvasMiniMapNSView.preferredSize
        let availableWidth = max(0, bounds.width - 32)
        let availableHeight = max(0, bounds.height - 32)
        let width = min(preferredSize.width, availableWidth)
        let height = min(preferredSize.height, availableHeight)
        minimapView.frame = CGRect(
            x: bounds.maxX - width - 16,
            y: bounds.minY + 16,
            width: width,
            height: height
        )
    }

    private func updateImageLayer() {
        let canvasImage = animatedFrameStore?.image ?? image
        guard let image = canvasImage, image.width > 0, image.height > 0 else {
            cancelInteractiveOverlayUpdates()
            if motionPhotoPlaybackController.hasMotionPhoto {
                motionPhotoPlaybackController.stopPlayback()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.isHidden = true
            motionPhotoPlaybackController.layer.isHidden = true
            CATransaction.commit()
            updateSelectionLayer()
            updateMiniMap()
            return
        }

        if animatedFrameStore == nil,
           renderQualityState.phase != .interactive {
            // Do not create or reconfigure the detail representation on every
            // drag/zoom frame. It is prepared by the settled path and reused
            // as one stable texture while the user is interacting.
            updateDetailProvider(for: image)
        }
        if animatedFrameStore == nil {
            setDisplayedImage(detailProvider?.detailImageIfAvailable() ?? image)
        } else {
            // The animated store owns the current contents. A transform update
            // must never replace it with the first frame supplied by SwiftUI.
            setDisplayedImage(image)
        }

        let isInteractive = renderQualityState.phase == .interactive
        let isDynamicPlaybackVisible = motionPhotoPlaybackController.isPlaybackVisible
        if isInteractive {
            transformState.translation = constrainedInteractiveTranslation(
                transformState.translation
            )
        } else {
            transformState.translation = CanvasTransformReducer.constrainedTranslation(
                for: transformState,
                proposed: transformState.translation
            )
        }
        let transform = isInteractive
            ? cachedInteractiveContentTransform()
            : CanvasTransformReducer.contentTransform(for: transformState)
        let imagePosition = CGPoint(
            x: bounds.midX + transformState.translation.x,
            y: bounds.midY + transformState.translation.y
        )
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: logicalImageSize.width,
            height: logicalImageSize.height
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.isHidden = isDynamicPlaybackVisible
        applyContentTransform(
            to: imageLayer,
            bounds: imageBounds,
            position: imagePosition,
            transform: transform
        )
        if motionPhotoPlaybackController.hasMotionPhoto {
            motionPhotoPlaybackController.layer.isHidden = !isDynamicPlaybackVisible
            applyContentTransform(
                to: motionPhotoPlaybackController.layer,
                bounds: imageBounds,
                position: imagePosition,
                transform: transform
            )
        }
        CATransaction.commit()

        if renderQualityState.phase == .interactive {
            // The minimap is a CALayer overlay, so updating it here keeps the
            // viewport box in lockstep with every pointer-driven transform.
            // The timer remains as a low-cost fallback for other overlay
            // changes, but is no longer the source of truth for panning.
            updateMiniMap()
            startInteractiveOverlayUpdates()
        } else {
            cancelInteractiveOverlayUpdates()
            updateSelectionLayer()
            updateMiniMap()
        }
    }

    private func displayAnimatedFrame(_ frame: CGImage?) {
        guard let frame,
              frame.width > 0,
              frame.height > 0 else {
            return
        }

        // Keep the CALayer geometry and transform alive while the user is
        // interacting. Swapping only the texture avoids re-running the
        // transform path for every GIF frame and prevents animation frames
        // from competing with pointer-driven pan/zoom updates.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setDisplayedImage(frame)
        imageLayer.isHidden = motionPhotoPlaybackController.isPlaybackVisible
        CATransaction.commit()
    }

    private func applyContentTransform(
        to contentLayer: CALayer,
        bounds: CGRect,
        position: CGPoint,
        transform: CGAffineTransform
    ) {
        if contentLayer.bounds != bounds {
            contentLayer.bounds = bounds
        }
        contentLayer.position = position
        contentLayer.setAffineTransform(transform)
    }

    private func setDisplayedImage(_ nextImage: CGImage?) {
        let changed: Bool
        switch (nextImage, displayedImage) {
        case (nil, nil):
            changed = false
        case let (next?, current?):
            changed = next !== current
        default:
            changed = true
        }
        guard changed else {
            return
        }
        displayedImage = nextImage
        imageLayer.contents = nextImage
    }

    private func scheduleMotionPhotoPlayback() {
        guard motionPhotoPlaybackController.hasMotionPhoto else {
            return
        }
        cancelPendingMotionPhotoClick()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.motionPhotoPlaybackController.hasMotionPhoto else {
                return
            }
            self.pendingMotionPhotoClick = nil
            self.motionPhotoPlaybackController.togglePlayback()
        }
        pendingMotionPhotoClick = workItem
        let delay = min(0.22, max(0.12, NSEvent.doubleClickInterval))
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func cancelPendingMotionPhotoClick() {
        pendingMotionPhotoClick?.cancel()
        pendingMotionPhotoClick = nil
    }

    private func setMotionPhotoPlaybackVisible(_ isVisible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        motionPhotoPlaybackController.layer.isHidden = !isVisible
        if isVisible {
            imageLayer.isHidden = true
        }
        CATransaction.commit()

        if !isVisible {
            updateImageLayer()
        }
    }

    private func startInteractiveOverlayUpdates() {
        guard (!minimapView.isHidden || !selectionLayer.isHidden),
              interactiveOverlayTimer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.renderQualityState.phase == .interactive else {
                return
            }
            guard !self.minimapView.isHidden || !self.selectionLayer.isHidden else {
                return
            }
            self.updateSelectionLayer()
            self.updateMiniMap()
        }
        interactiveOverlayTimer = timer
        timer.schedule(
            deadline: .now() + .milliseconds(33),
            repeating: .milliseconds(33),
            leeway: .milliseconds(8)
        )
        timer.resume()
    }

    private func cancelInteractiveOverlayUpdates() {
        interactiveOverlayTimer?.setEventHandler {}
        interactiveOverlayTimer?.cancel()
        interactiveOverlayTimer = nil
    }

    private var logicalImageSize: CGSize {
        guard sourcePixelSize.width > 0, sourcePixelSize.height > 0 else {
            return CGSize(
                width: image?.width ?? 0,
                height: image?.height ?? 0
            )
        }
        return sourcePixelSize
    }

    private func updateDetailProvider(for image: CGImage) {
        let pixelSize = ImageTilePixelSize(
            width: max(0, Int(logicalImageSize.width.rounded())),
            height: max(0, Int(logicalImageSize.height.rounded()))
        )
        guard pixelSize.isLargeImage else {
            invalidateDetailProvider()
            return
        }

        let descriptor = ImageTileDescriptor(
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height,
            tileSize: 512,
            proxyMaxPixelSize: ImageTilePixelSize.interactiveMaxPixelSize
        )
        let imageID = ObjectIdentifier(image)
        if detailProvider == nil
            || detailDescriptor != descriptor
            || detailProviderImageID != imageID {
            invalidateDetailProvider()
            detailDescriptor = descriptor
            detailProviderImageID = imageID
            detailProvider = ImageTileProvider(
                descriptor: descriptor,
                proxyImage: image,
                sourceURL: sourceURL,
                onDetailReady: { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        self?.updateImageLayer()
                    }
                }
            )
        }

        let effectiveScale = CanvasTransformReducer.effectiveScale(for: transformState)
        detailProvider?.setHighResolutionEnabled(
            renderQualityState.phase == .settled
                && (transformState.mode == .actualSize || effectiveScale >= 1)
        )
    }

    private func invalidateDetailProvider() {
        detailProvider?.cancelOutstandingRequests()
        detailProvider = nil
        detailDescriptor = nil
        detailProviderImageID = nil
    }

    private func updateSelectionLayer() {
        guard logicalImageSize.width > 0, logicalImageSize.height > 0,
              let normalized = selectionPreview ?? (isCropSelectionMode ? cropSelection : nil) ?? selection,
              isSelectionMode || isCropSelectionMode || selection != nil || selectionPreview != nil else {
            selectionLayer.isHidden = true
            selectionLayer.path = nil
            return
        }

        let clamped = normalized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard clamped.width > 0, clamped.height > 0 else {
            selectionLayer.isHidden = true
            selectionLayer.path = nil
            return
        }

        let imageSize = logicalImageSize
        let imageRect = CGRect(
            x: -imageSize.width / 2 + clamped.minX * imageSize.width,
            y: -imageSize.height / 2 + clamped.minY * imageSize.height,
            width: clamped.width * imageSize.width,
            height: clamped.height * imageSize.height
        )
        var transform = displayTransform()
        selectionLayer.path = CGPath(rect: imageRect, transform: &transform)
        selectionLayer.isHidden = false
    }

    private func displayTransform() -> CGAffineTransform {
        guard renderQualityState.phase == .interactive else {
            return CanvasTransformReducer.viewTransform(for: transformState)
        }
        // Keep the interactive hit-test/selection transform identical to the
        // CALayer path: transform the image around its center first, then
        // apply the layer position. Applying translation before the scale
        // would move the sampled point when zoom is above 1×.
        return cachedInteractiveContentTransform().concatenating(
            CGAffineTransform(
                translationX: transformState.viewportSize.width / 2 + transformState.translation.x,
                y: transformState.viewportSize.height / 2 + transformState.translation.y
            )
        )
    }

    private func cachedInteractiveContentTransform() -> CGAffineTransform {
        prepareInteractiveGeometry()
        return interactiveContentTransform
    }

    private func constrainedInteractiveTranslation(_ proposed: CGPoint) -> CGPoint {
        prepareInteractiveGeometry()
        guard transformState.mode != .infinite,
              transformState.viewportSize.width > 0,
              transformState.viewportSize.height > 0 else {
            return proposed
        }
        return CGPoint(
            x: min(
                interactiveTranslationOverflow.width,
                max(-interactiveTranslationOverflow.width, proposed.x)
            ),
            y: min(
                interactiveTranslationOverflow.height,
                max(-interactiveTranslationOverflow.height, proposed.y)
            )
        )
    }

    private func interactiveTranslation(forViewportCenter center: CGPoint) -> CGPoint {
        prepareInteractiveGeometry()
        guard transformState.imagePixelSize.width > 0,
              transformState.imagePixelSize.height > 0 else {
            return transformState.translation
        }

        let clampedCenter = CGPoint(
            x: min(1, max(0, center.x)),
            y: min(1, max(0, center.y))
        )
        let imagePoint = CGPoint(
            x: (clampedCenter.x - 0.5) * transformState.imagePixelSize.width,
            y: (clampedCenter.y - 0.5) * transformState.imagePixelSize.height
        )
        let transformedPoint = imagePoint.applying(interactiveContentTransform)
        return constrainedInteractiveTranslation(
            CGPoint(x: -transformedPoint.x, y: -transformedPoint.y)
        )
    }

    private func prepareInteractiveGeometry() {
        let key = InteractiveGeometryKey(state: transformState)
        guard interactiveGeometryKey != key else {
            return
        }

        interactiveGeometryKey = key
        interactiveContentTransform = CanvasTransformReducer.contentTransform(
            for: transformState
        )
        guard transformState.mode != .infinite,
              transformState.viewportSize.width > 0,
              transformState.viewportSize.height > 0 else {
            interactiveTranslationOverflow = .zero
            return
        }

        let contentSize = CanvasTransformReducer.transformedImageSize(for: transformState)
        interactiveTranslationOverflow = CGSize(
            width: max(0, (contentSize.width - transformState.viewportSize.width) / 2),
            height: max(0, (contentSize.height - transformState.viewportSize.height) / 2)
        )
    }

    private func normalizedSelection(from start: CGPoint, to end: CGPoint) -> CGRect? {
        guard logicalImageSize.width > 0, logicalImageSize.height > 0 else {
            return nil
        }

        let imageSize = logicalImageSize
        let inverse = displayTransform().inverted()
        let first = start.applying(inverse)
        let second = end.applying(inverse)
        let imageBounds = CGRect(
            x: -imageSize.width / 2,
            y: -imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        let dragRect = CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(first.x - second.x),
            height: abs(first.y - second.y)
        )
        let clipped = dragRect.intersection(imageBounds)
        guard clipped.width >= 2, clipped.height >= 2 else {
            return nil
        }

        return CGRect(
            x: (clipped.minX - imageBounds.minX) / imageBounds.width,
            y: (clipped.minY - imageBounds.minY) / imageBounds.height,
            width: clipped.width / imageBounds.width,
            height: clipped.height / imageBounds.height
        )
    }

    private func normalizedImagePoint(from point: CGPoint) -> CGPoint? {
        guard logicalImageSize.width > 0, logicalImageSize.height > 0 else {
            return nil
        }
        let imageSize = logicalImageSize
        let inverse = displayTransform().inverted()
        let imagePoint = point.applying(inverse)
        let imageBounds = CGRect(
            x: -imageSize.width / 2,
            y: -imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        guard imageBounds.contains(imagePoint) else {
            return nil
        }
        return CGPoint(
            x: (imagePoint.x - imageBounds.minX) / imageBounds.width,
            y: (imagePoint.y - imageBounds.minY) / imageBounds.height
        )
    }

    func synchronizeModelState(
        displayMode: CanvasDisplayMode,
        zoomFactor: CGFloat,
        rotationDegrees: Double,
        isFlippedHorizontally: Bool
    ) {
        synchronizeDisplayModeFromModel(displayMode)
        if transformState.rotationDegrees != rotationDegrees {
            applyTransformCommand(.setRotation(rotationDegrees))
        }
        if transformState.isFlippedHorizontally != isFlippedHorizontally {
            applyTransformCommand(.setFlipHorizontally(isFlippedHorizontally))
        }
        synchronizeZoomFactorFromModel(zoomFactor)
    }

    func synchronizeZoomFactorFromModel(_ value: CGFloat) {
        let clamped = CanvasTransformReducer.clampedScale(value)

        if let pendingNativeZoom {
            if isApproximatelyEqual(clamped, pendingNativeZoom) {
                self.pendingNativeZoom = nil
                cancelZoomCommitTimer()
                lastModelZoomFactor = clamped
                return
            }

            if isApproximatelyEqual(clamped, lastModelZoomFactor) {
                return
            }

            cancelZoomCommit()
        }

        lastModelZoomFactor = clamped
        if !isApproximatelyEqual(transformState.scale, clamped) {
            applyTransformCommand(.setScale(clamped, anchor: nil))
        }
    }

    private func synchronizeDisplayModeFromModel(_ mode: CanvasDisplayMode) {
        guard transformState.mode != mode else {
            return
        }
        cancelZoomCommit()
        applyTransformCommand(.setMode(mode))
        lastModelZoomFactor = transformState.scale
    }

    private func applyTransformCommand(_ command: CanvasTransformCommand) {
        let nextState = CanvasTransformReducer.reduce(transformState, command)
        guard nextState != transformState else {
            return
        }
        cancelSettledRendering()
        renderQualityState.reset()
        applySampling(for: .settled)
        let modeChanged = nextState.mode != transformState.mode
        transformState = nextState
        if modeChanged {
            updateCanvasBackground()
        }
        updateImageLayer()
    }

    private func applyInteractiveTransformCommand(_ command: CanvasTransformCommand) {
        beginInteractiveRendering()
        let nextState: CanvasTransformState
        switch command {
        case let .setTranslation(proposed):
            var next = transformState
            next.translation = constrainedInteractiveTranslation(proposed)
            nextState = next
        case let .moveViewport(center):
            var next = transformState
            next.translation = interactiveTranslation(forViewportCenter: center)
            nextState = next
        default:
            nextState = CanvasTransformReducer.reduce(transformState, command)
        }
        guard nextState != transformState else {
            return
        }
        let modeChanged = nextState.mode != transformState.mode
        transformState = nextState
        if modeChanged {
            updateCanvasBackground()
        }
        // Apply the transform immediately so pointer input never waits behind
        // an asynchronous work item before reaching the display layer.
        updateImageLayer()
    }

    func moveViewport(to normalizedCenter: CGPoint) {
        guard logicalImageSize.width > 0,
              logicalImageSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }

        applyInteractiveTransformCommand(.moveViewport(center: normalizedCenter))
    }

    private func setZoom(_ value: CGFloat, around anchor: CGPoint? = nil) {
        let clamped = CanvasTransformReducer.clampedScale(value)
        applyInteractiveTransformCommand(.setScale(clamped, anchor: anchor))
        pendingNativeZoom = clamped
        scheduleZoomNotification()
    }

    private func beginInteractiveRendering() {
        let previousPhase = renderQualityState.phase
        renderQualityState.beginInteraction()
        if previousPhase != .interactive {
            detailProvider?.cancelOutstandingRequests()
            applySampling(for: .interactive)
            updateImageLayer()
            PerformanceLog.event("CanvasInteractionBegin")
        }
        scheduleSettledRendering()
    }

    private func scheduleSettledRendering() {
        if settledRenderTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in
                self?.finishSettledRendering()
            }
            settledRenderTimer = timer
            timer.resume()
        }
        settledRenderTimer?.schedule(
            deadline: .now() + .milliseconds(100),
            repeating: .never,
            leeway: .milliseconds(4)
        )
    }

    private func cancelSettledRendering() {
        settledRenderTimer?.setEventHandler {}
        settledRenderTimer?.cancel()
        settledRenderTimer = nil
    }

    private func finishSettledRendering() {
        settledRenderTimer?.setEventHandler {}
        settledRenderTimer?.cancel()
        settledRenderTimer = nil
        guard let request = renderQualityState.consumeSettledRequest(),
              renderQualityState.accepts(request) else {
            return
        }
        cancelInteractiveOverlayUpdates()
        applySampling(for: .settled)
        updateImageLayer()
        PerformanceLog.event("CanvasSettledFrame")
    }

    private func applySampling(for phase: CanvasRenderPhase) {
        switch phase {
        case .interactive:
            imageLayer.magnificationFilter = .linear
            imageLayer.minificationFilter = .linear
        case .settled:
            imageLayer.magnificationFilter = .linear
            imageLayer.minificationFilter = .trilinear
        }
    }

    private func updateMiniMap() {
        guard let image = animatedFrameStore?.image ?? image,
              image.width > 0,
              image.height > 0,
              bounds.width > 0,
              bounds.height > 0,
              transformState.scale > 1.01 else {
            minimapView.isHidden = true
            return
        }

        minimapView.isHidden = false
        minimapView.update(
            image: image,
            viewport: currentViewportRect()
        )
    }

    private func currentViewportRect() -> CGRect? {
        CanvasTransformReducer.normalizedViewport(for: transformState)
    }

    private func isApproximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.0001
    }

    private func scheduleZoomNotification() {
        if zoomCommitTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in
                self?.commitZoomNotification()
            }
            zoomCommitTimer = timer
            timer.resume()
        }
        zoomCommitTimer?.schedule(
            deadline: .now() + .milliseconds(80),
            repeating: .never,
            leeway: .milliseconds(4)
        )
    }

    private func cancelZoomCommit() {
        cancelZoomCommitTimer()
        pendingNativeZoom = nil
    }

    private func cancelZoomCommitTimer() {
        zoomCommitTimer?.setEventHandler {}
        zoomCommitTimer?.cancel()
        zoomCommitTimer = nil
    }

    private func commitZoomNotification() {
        cancelZoomCommitTimer()
        guard let pendingNativeZoom else {
            return
        }
        self.pendingNativeZoom = nil
        lastModelZoomFactor = pendingNativeZoom
        onZoomChange?(pendingNativeZoom)
    }

    private var effectiveMouseSensitivity: CGFloat {
        guard mouseSensitivity.isFinite else {
            return 1
        }
        return min(
            CGFloat(MouseSensitivityConfiguration.range.upperBound),
            max(CGFloat(MouseSensitivityConfiguration.range.lowerBound), mouseSensitivity)
        )
    }

}
