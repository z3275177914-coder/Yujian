import AppKit
import ImageViewerCore
import SwiftUI

enum SidebarMode: String, CaseIterable, Identifiable {
    case folder = "文件夹"
    case thumbnails = "缩略图"
    case gallery = "图库"

    var id: String { rawValue }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case info = "信息"
    case adjust = "调整"
    case ai = "AI"

    var id: String { rawValue }
}

enum MouseSensitivityConfiguration {
    static let key = "ImageViewer.mouseSensitivity"
    static let `default` = 1.0
    static let range: ClosedRange<Double> = 0.25...3.0

    static func load() -> Double {
        let stored = UserDefaults.standard.double(forKey: key)
        guard stored.isFinite, stored > 0 else {
            return `default`
        }
        return clamped(stored)
    }

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else {
            return `default`
        }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

private enum PendingCloudAIAction {
    case analysis(AIAction)
    case chatGPT
}

@MainActor
final class PixelSampleStore: ObservableObject {
    @Published private(set) var value: PixelSample?

    func update(_ value: PixelSample?) {
        guard self.value != value else {
            return
        }
        self.value = value
    }
}

/// Delivers animated frames directly to the AppKit canvas. It deliberately
/// does not conform to ObservableObject: publishing every GIF frame would
/// rebuild the SwiftUI workbench and compete with pointer input.
@MainActor
final class AnimatedFrameStore {
    typealias Observer = (CGImage?) -> Void

    private(set) var image: CGImage?
    private var observers: [UUID: Observer] = [:]

    func update(_ image: CGImage?) {
        let previousID = self.image.map(ObjectIdentifier.init)
        let nextID = image.map(ObjectIdentifier.init)
        guard previousID != nextID else {
            return
        }
        self.image = image
        let callbacks = Array(observers.values)
        callbacks.forEach { $0(image) }
    }

    @discardableResult
    func addObserver(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        observers[token] = observer
        observer(image)
        return token
    }

    func removeObserver(_ token: UUID) {
        observers[token] = nil
    }
}

@MainActor
final class ImageViewerModel: ObservableObject {
    @Published private(set) var assets: [ImageAsset] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var currentImage: CGImage? {
        didSet {
            scheduleAdjustedImage()
        }
    }
    @Published private(set) var currentDisplayImage: CGImage? {
        didSet {
            scheduleInspection()
        }
    }
    @Published private(set) var currentAnimation: AnimatedImageSession?
    @Published private(set) var currentMotionPhoto: MotionPhotoInfo?
    @Published private(set) var metadata: ImageMetadata?
    @Published private(set) var isLoading = false
    @Published private(set) var histogram: ImageHistogram?
    @Published private(set) var isInspectionLoading = false

    let pixelSampleStore = PixelSampleStore()
    let animatedFrameStore = AnimatedFrameStore()

    @Published var canvasMode: CanvasDisplayMode = .fit
    @Published var zoomFactor: CGFloat = 1
    @Published var mouseSensitivity = MouseSensitivityConfiguration.load() {
        didSet {
            let clamped = MouseSensitivityConfiguration.clamped(mouseSensitivity)
            if clamped != mouseSensitivity {
                mouseSensitivity = clamped
                return
            }
            UserDefaults.standard.set(mouseSensitivity, forKey: MouseSensitivityConfiguration.key)
        }
    }
    @Published var rotationDegrees: Double = 0
    @Published var isFlippedHorizontally = false
    @Published private(set) var adjustments = ImageAdjustments.default {
        didSet {
            scheduleAdjustedImage()
        }
    }
    @Published private(set) var editRecipe = EditRecipe.empty

    @Published var sidebarMode: SidebarMode = .thumbnails
    @Published var inspectorTab: InspectorTab = .info
    @Published var localToolPermissions = LocalToolPermissions.load()
    @Published var aiPrompt = ""
    @Published var aiInputSource: AIInputSource = .original
    @Published var aiResultText = ""
    @Published var isAIRequesting = false
    @Published var isAISelectionMode = false
    @Published var aiSelection: CGRect?
    @Published var isCropSelectionMode = false
    @Published private(set) var cropSelection: CGRect?
    @Published private(set) var aiHistory: [AIHistoryEntry] = []
    @Published var selectedAIProvider = AIProviderKind.loadSelected()
    @Published var aiModel = AIProviderConfiguration.load(
        for: AIProviderKind.loadSelected()
    ).model
    @Published var aiBaseURL = AIProviderConfiguration.load(
        for: AIProviderKind.loadSelected()
    ).baseURL
    @Published private(set) var aiAPIKeyConfigured = KeychainStore.hasAPIKey(
        for: AIProviderKind.loadSelected()
    )
    @Published var statusMessage: String?
    @Published var shortcuts = ShortcutConfiguration.load()
    @Published var aiPrivacyPreferences = AIPrivacyPreferences.load() {
        didSet {
            aiPrivacyPreferences.save()
            guard oldValue.historyRetention != aiPrivacyPreferences.historyRetention else {
                return
            }
            let retention = aiPrivacyPreferences.historyRetention
            Task.detached(priority: .utility) {
                try? AIHistoryStore.pruneExpired(retention: retention)
            }
        }
    }
    @Published var isShowingAIPrivacyNotice = false
    @Published var isShowingTrashConfirmation = false
    @Published var isShowingLocalToolConfirmation = false
    @Published private(set) var isAITestingConnection = false

    @Published var isShowingExportPanel = false
    @Published var isShowingBatchConvertPanel = false
    @Published var isShowingBatchRenamePanel = false
    @Published var isShowingOriginalPreview = false

    private let directorySession = DirectorySession()
    private let motionPhotoDetector = MotionPhotoDetector()
    let sessionCoordinator = ViewerSessionCoordinator()
    private var editHistory = EditHistory()
    private var currentImageSession: ViewerImageSessionID?
    private var directoryWatcher: DirectoryWatcher?
    private var directoryRefreshWorkItem: DispatchWorkItem?
    private var aiConnectionTask: Task<Void, Never>?
    private var pendingCloudAIAction: PendingCloudAIAction?
    private var pendingTrashAssetID: String?
    private var pendingLocalToolRequest: LocalToolRequest?
    private var queuedLocalToolRequests: [LocalToolRequest] = []

    var currentAsset: ImageAsset? {
        guard assets.indices.contains(currentIndex) else {
            return nil
        }
        return assets[currentIndex]
    }

    // Kept as a narrow module-internal seam for the animation extension. The
    // assignment still goes through the same published property and retains
    // the existing edited-preview behavior.
    func updateCurrentImageForAnimation(_ image: CGImage) {
        currentImage = image
    }

    var trashConfirmationFilename: String {
        if let pendingTrashAssetID,
           let asset = assets.first(where: { $0.id == pendingTrashAssetID }) {
            return asset.filename
        }
        return currentAsset?.filename ?? "当前图片"
    }

    var localToolConfirmationPath: String {
        pendingLocalToolRequest?.path ?? "未提供路径"
    }

    var directoryURL: URL? {
        currentAsset?.url.deletingLastPathComponent()
    }

    var zoomLabel: String {
        if zoomFactor == 1 {
            switch canvasMode {
            case .fit:
                return "适应窗口"
            case .infinite:
                return "无限画布"
            case .actualSize:
                return "100%"
            }
        }
        let percentage = "\(Int(zoomFactor * 100))%"
        return canvasMode == .infinite ? "无限 · \(percentage)" : percentage
    }

    var zoomPercentageInput: String {
        "\(Int((zoomFactor * 100).rounded()))"
    }

    var mouseSensitivityLabel: String {
        "\(Int((mouseSensitivity * 100).rounded()))%"
    }

    var hasPreviewEdits: Bool {
        !editRecipe.isEmpty
    }

    var canUndoEdits: Bool {
        editHistory.canUndo
    }

    var canRedoEdits: Bool {
        editHistory.canRedo
    }

    var aiProviderDisplayName: String {
        selectedAIProvider.displayName
    }

    var aiProviderSupportsImageEditing: Bool {
        selectedAIProvider.supportsImageEditing
    }

    var aiProviderCapabilities: AIProviderCapabilities {
        selectedAIProvider.capabilities
    }

    func openPanel() {
        guard let url = FileOperations.chooseImage() else {
            return
        }
        open(url: url)
    }

    func open(url: URL) {
        guard ImageAsset.isSupportedImage(url) else {
            statusMessage = "此文件不是受支持的图片格式。"
            return
        }

        PerformanceLog.event("OpenImage")
        let asset = ImageAsset(url: url)
        assets = [asset]
        currentIndex = 0
        resetViewState()
        loadCurrentImage()
        scanDirectory(seed: asset)
    }

    func previousImage() {
        move(by: -1)
    }

    func nextImage() {
        move(by: 1)
    }

    func select(asset: ImageAsset) {
        guard let index = assets.firstIndex(where: { $0.id == asset.id }) else {
            return
        }
        guard index != currentIndex else {
            return
        }
        let direction: ImagePrefetchDirection = index < currentIndex ? .backward : .forward
        currentIndex = index
        resetViewState()
        loadCurrentImage()
        prefetchNeighbors(direction: direction)
    }

    func fitImage() {
        setDisplayMode(.fit)
    }

    func actualSize() {
        setDisplayMode(.actualSize)
    }

    func infiniteCanvas() {
        setDisplayMode(.infinite)
    }

    func setDisplayMode(_ mode: CanvasDisplayMode) {
        canvasMode = mode
        zoomFactor = 1
        if mode == .actualSize {
            loadCurrentImage()
        }
    }

    func zoomIn() {
        zoomFactor = min(20, zoomFactor * 1.25)
    }

    func zoomOut() {
        zoomFactor = max(0.05, zoomFactor / 1.25)
    }

    func setZoomFactor(_ factor: CGFloat) {
        zoomFactor = min(20, max(0.05, factor))
    }

    func resetMouseSensitivity() {
        mouseSensitivity = MouseSensitivityConfiguration.default
    }

    func rotateLeft() {
        recordEditRecipe(
            recipeForCurrentEdits(
                adjustments: adjustments,
                rotationDegrees: rotationDegrees - 90,
                isFlippedHorizontally: isFlippedHorizontally
            )
        )
    }

    func rotateRight() {
        recordEditRecipe(
            recipeForCurrentEdits(
                adjustments: adjustments,
                rotationDegrees: rotationDegrees + 90,
                isFlippedHorizontally: isFlippedHorizontally
            )
        )
    }

    func toggleFlip() {
        recordEditRecipe(
            recipeForCurrentEdits(
                adjustments: adjustments,
                rotationDegrees: rotationDegrees,
                isFlippedHorizontally: !isFlippedHorizontally
            )
        )
    }

    func setAdjustment(
        _ keyPath: WritableKeyPath<ImageAdjustments, Double>,
        value: Double
    ) {
        var updated = adjustments
        updated[keyPath: keyPath] = value
        recordEditRecipe(
            recipeForCurrentEdits(
                adjustments: updated.clamped,
                rotationDegrees: rotationDegrees,
                isFlippedHorizontally: isFlippedHorizontally
            ),
            coalescingKey: String(describing: keyPath)
        )
    }

    func resetAdjustments() {
        recordEditRecipe(.empty)
    }

    func undoEdits() {
        guard let recipe = editHistory.undo() else {
            return
        }
        applyEditRecipe(recipe)
    }

    func redoEdits() {
        guard let recipe = editHistory.redo() else {
            return
        }
        applyEditRecipe(recipe)
    }

    func toggleOriginalPreview() {
        isShowingOriginalPreview.toggle()
        scheduleInspection()
    }

    func samplePixel(at normalizedPoint: CGPoint?) {
        guard let normalizedPoint else {
            pixelSampleStore.update(nil)
            return
        }
        let image = isShowingOriginalPreview
            ? currentImage
            : currentDisplayImage ?? currentImage
        pixelSampleStore.update(image.flatMap {
            PixelSampler.sample(image: $0, at: normalizedPoint)
        })
    }

    func beginCrop() {
        guard currentImage != nil else {
            statusMessage = "请先打开图片。"
            return
        }
        isCropSelectionMode = true
        isAISelectionMode = false
        statusMessage = "请在图片上拖出裁剪区域。"
    }

    func updateCropSelection(_ selection: CGRect?) {
        isCropSelectionMode = false
        cropSelection = selection
        recordEditRecipe(
            recipeForCurrentEdits(
                adjustments: adjustments,
                rotationDegrees: rotationDegrees,
                isFlippedHorizontally: isFlippedHorizontally
            )
        )
        statusMessage = selection == nil ? "未应用裁剪。" : "裁剪区域已应用。"
    }

    func clearCrop() {
        cropSelection = nil
        isCropSelectionMode = false
        recordEditRecipe(
            recipeForCurrentEdits(
                adjustments: adjustments,
                rotationDegrees: rotationDegrees,
                isFlippedHorizontally: isFlippedHorizontally
            )
        )
        statusMessage = "已清除裁剪。"
    }

    func showAI() {
        inspectorTab = .ai
    }

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    func revealInFinder() {
        guard let url = currentAsset?.url else {
            return
        }
        FileOperations.revealInFinder(url)
    }

    func copyCurrentImage() {
        guard let currentImage else {
            return
        }

        let image = NSImage(
            cgImage: currentImage,
            size: NSSize(width: currentImage.width, height: currentImage.height)
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        statusMessage = "图片已复制到剪贴板。"
    }

    func copyCurrentPath() {
        guard let path = currentAsset?.url.path else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        statusMessage = "路径已复制到剪贴板。"
    }

    func saveAs() {
        guard let asset = currentAsset else {
            return
        }

        let baseName = asset.url.deletingPathExtension().lastPathComponent
        let defaultFormat = ImageExportFormat.from(fileExtension: asset.fileExtension) ?? .png
        let extensionName = defaultFormat.fileExtension
        let defaultName = "\(baseName)-copy.\(extensionName)"
        guard let destinationURL = FileOperations.chooseSaveLocation(defaultName: defaultName) else {
            return
        }

        do {
            let format = ImageExportFormat.from(fileExtension: destinationURL.pathExtension) ?? defaultFormat
            try ImageExportService.export(
                sourceURL: asset.url,
                destinationURL: destinationURL,
                format: format,
                recipe: editRecipe
            )
            statusMessage = "已将副本保存为 \(destinationURL.lastPathComponent)。"
        } catch {
            statusMessage = "无法保存副本：\(error.localizedDescription)"
        }
    }

    func moveCurrentToTrash() {
        guard let asset = currentAsset else {
            return
        }

        pendingTrashAssetID = asset.id
        isShowingTrashConfirmation = true
    }

    func cancelMoveCurrentToTrash() {
        pendingTrashAssetID = nil
        isShowingTrashConfirmation = false
    }

    func confirmMoveCurrentToTrash() {
        guard let pendingTrashAssetID,
              let removedIndex = assets.firstIndex(where: { $0.id == pendingTrashAssetID }) else {
            cancelMoveCurrentToTrash()
            return
        }
        self.pendingTrashAssetID = nil
        isShowingTrashConfirmation = false
        moveAssetToTrash(at: removedIndex)
    }

    private func moveAssetToTrash(at removedIndex: Int) {
        guard assets.indices.contains(removedIndex) else {
            return
        }
        let asset = assets[removedIndex]
        let removedCurrentAsset = currentAsset?.id == asset.id

        do {
            try FileOperations.moveToTrash(asset.url)
            assets.remove(at: removedIndex)

            if assets.isEmpty {
                currentIndex = 0
                currentImage = nil
                metadata = nil
                currentAnimation?.close()
                currentAnimation = nil
                animatedFrameStore.update(nil)
                currentMotionPhoto = nil
                sessionCoordinator.cancel(.animation)
                sessionCoordinator.cancel(.motionPhoto)
                aiHistory = []
                aiResultText = ""
                isLoading = false
                statusMessage = "已将 \(asset.filename) 移到废纸篓。"
                return
            }

            guard removedCurrentAsset else {
                if removedIndex < currentIndex {
                    currentIndex -= 1
                }
                currentIndex = min(currentIndex, assets.count - 1)
                statusMessage = "已将 \(asset.filename) 移到废纸篓。"
                return
            }

            currentIndex = min(removedIndex, assets.count - 1)
            resetViewState()
            loadCurrentImage()
            statusMessage = "已将 \(asset.filename) 移到废纸篓。"
        } catch {
            statusMessage = "无法将文件移到废纸篓：\(error.localizedDescription)"
        }
    }

    func openInChatGPT() {
        guard let asset = currentAsset else {
            statusMessage = "请先打开图片，再将它发送到 ChatGPT。"
            return
        }

        guard aiPrivacyPreferences.cloudAIConsentGranted else {
            pendingCloudAIAction = .chatGPT
            isShowingAIPrivacyNotice = true
            return
        }

        let provider = ChatGPTExternalProvider()
        let prompt = aiPrompt
        let clearClipboardAfter = aiPrivacyPreferences.clearClipboardAfterHandoff ? 30.0 : nil
        guard aiInputSource != .original || aiSelection != nil || !hasPreviewEdits else {
            let request = provider.makeRequest(imageURL: asset.url, prompt: prompt)
            statusMessage = AIHandoffService.openInChatGPT(
                request: request,
                clearPasteboardAfter: clearClipboardAfter
            )
            return
        }

        let assetID = asset.id
        let originalURL = asset.url
        let inputSource = aiInputSource
        let selection = aiSelection.map(AIImageSelection.init)
        let recipe = editRecipe
        let handoffTaskID = sessionCoordinator.start(.ai)
        statusMessage = "正在准备 ChatGPT 输入（来源：\(inputSource.displayName)）…"
        let handoffTask = Task { [weak self] in
            do {
                let input = try await Task.detached(priority: .userInitiated) {
                    try AIInputService.prepare(
                        sourceURL: originalURL,
                        source: inputSource,
                        recipe: recipe,
                        selection: selection,
                        action: .describe,
                        capabilities: AIProviderKind.openAI.capabilities
                    )
                }.value
                defer {
                    AIInputService.cleanup(input)
                }
                guard !Task.isCancelled,
                      let self,
                      self.sessionCoordinator.isCurrent(handoffTaskID, for: .ai),
                      self.currentAsset?.id == assetID else {
                    return
                }
                let request = provider.makeRequest(imageURL: input.url, prompt: prompt)
                self.statusMessage = AIHandoffService.openInChatGPT(
                    request: request,
                    clearPasteboardAfter: clearClipboardAfter
                )
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.sessionCoordinator.isCurrent(handoffTaskID, for: .ai),
                      self.currentAsset?.id == assetID else {
                    return
                }
                self.statusMessage = "无法准备 ChatGPT 图片：\(error.localizedDescription)"
            }
        }
        sessionCoordinator.track(handoffTask, for: .ai)
    }

    func acceptCloudAIPrivacyNotice() {
        aiPrivacyPreferences.cloudAIConsentGranted = true
        let pendingAction = pendingCloudAIAction
        pendingCloudAIAction = nil
        isShowingAIPrivacyNotice = false

        switch pendingAction {
        case let .analysis(action):
            runAI(action)
        case .chatGPT:
            openInChatGPT()
        case nil:
            break
        }
    }

    func declineCloudAIPrivacyNotice() {
        pendingCloudAIAction = nil
        isShowingAIPrivacyNotice = false
        statusMessage = "已取消云端 AI 操作。"
    }

    func revokeCloudAIPrivacyConsent() {
        aiPrivacyPreferences.cloudAIConsentGranted = false
        statusMessage = "下次使用云端 AI 时将再次显示隐私提示。"
    }

    func beginAISelection() {
        guard currentAsset != nil else {
            statusMessage = "请先打开图片。"
            return
        }
        isAISelectionMode = true
        statusMessage = "请在图片上拖出要交给 AI 的局部区域。"
    }

    func updateAISelection(_ selection: CGRect?) {
        aiSelection = selection
        isAISelectionMode = false
        if selection == nil {
            statusMessage = "已清除 AI 局部选区。"
        } else {
            statusMessage = "AI 局部选区已更新。"
        }
    }

    func clearAISelection() {
        aiSelection = nil
        isAISelectionMode = false
        statusMessage = "已清除 AI 局部选区。"
    }

    func runAI(_ action: AIAction) {
        guard !isAIRequesting else {
            return
        }
        guard let asset = currentAsset else {
            statusMessage = "请先打开图片。"
            return
        }

        let prompt = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == .edit, prompt.isEmpty {
            statusMessage = "请先输入 AI 编辑要求。"
            return
        }

        if action != .ocr,
           !aiPrivacyPreferences.cloudAIConsentGranted {
            pendingCloudAIAction = .analysis(action)
            isShowingAIPrivacyNotice = true
            return
        }

        let assetID = asset.id
        let originalURL = asset.url
        let selection = aiSelection.map(AIImageSelection.init)
        let inputSource = aiInputSource
        let recipe = editRecipe
        let providerKind = selectedAIProvider
        let providerConfiguration = AIProviderConfiguration(
            provider: providerKind,
            model: aiModel,
            baseURL: aiBaseURL
        )
        let providerModel = providerConfiguration.model
        let providerBaseURL = providerConfiguration.baseURL
        let providerAPIKey = KeychainStore.loadAPIKey(for: providerKind)
        isAIRequesting = true
        statusMessage = "正在处理：\(action.rawValue)（来源：\(inputSource.displayName)）…"

        let aiTaskID = sessionCoordinator.start(.ai)
        let aiTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.isAIRequesting = false
            }

            do {
                let capabilities = providerKind.capabilities
                let preparedInput = try await Task.detached(priority: .userInitiated) {
                    try AIInputService.prepare(
                        sourceURL: originalURL,
                        source: inputSource,
                        recipe: recipe,
                        selection: selection,
                        action: action,
                        capabilities: capabilities
                    )
                }.value
                defer {
                    AIInputService.cleanup(preparedInput)
                }
                let inputURL = preparedInput.url
                let inputByteCount = preparedInput.byteCount

                switch action {
                case .ocr:
                    let text = try await LocalOCRService.recognizeText(
                        in: inputURL
                    )
                    let result = text.isEmpty ? "未识别到文字。" : text
                    let entry = try await Task.detached(priority: .utility) {
                        try AIHistoryStore.saveText(
                            originalURL: originalURL,
                            action: action,
                            prompt: "本地 OCR",
                            text: result,
                            inputSource: inputSource,
                            inputByteCount: inputByteCount
                        )
                    }.value
                    guard !Task.isCancelled,
                          self.sessionCoordinator.isCurrent(aiTaskID, for: .ai),
                          self.currentAsset?.id == assetID else {
                        return
                    }
                    self.aiResultText = result
                    self.aiHistory.insert(entry, at: 0)
                    self.statusMessage = "文字识别完成。"

                case .ask, .describe, .caption:
                    let provider = makeAIProvider(
                        kind: providerKind,
                        model: providerModel,
                        baseURL: providerBaseURL,
                        apiKey: providerAPIKey
                    )
                    let result: String
                    switch action {
                    case .ask:
                        result = try await provider.ask(
                            imageURL: inputURL,
                            prompt: prompt,
                            selection: nil
                        )
                    case .describe:
                        result = try await provider.describe(
                            imageURL: inputURL,
                            selection: nil
                        )
                    case .caption:
                        result = try await provider.generateCaption(
                            imageURL: inputURL,
                            selection: nil
                        )
                    case .ocr, .edit:
                        return
                    }
                    let entry = try await Task.detached(priority: .utility) {
                        try AIHistoryStore.saveText(
                            originalURL: originalURL,
                            action: action,
                            prompt: prompt,
                            text: result,
                            inputSource: inputSource,
                            inputByteCount: inputByteCount
                        )
                    }.value
                    guard !Task.isCancelled,
                          self.sessionCoordinator.isCurrent(aiTaskID, for: .ai),
                          self.currentAsset?.id == assetID else {
                        return
                    }
                    self.aiResultText = result
                    self.aiHistory.insert(entry, at: 0)
                    self.statusMessage = "\(action.rawValue)完成。"

                case .edit:
                    let provider = makeAIProvider(
                        kind: providerKind,
                        model: providerModel,
                        baseURL: providerBaseURL,
                        apiKey: providerAPIKey
                    )
                    let imageData = try await provider.edit(
                        imageURL: inputURL,
                        prompt: prompt,
                        selection: nil
                    )
                    let entry = try await Task.detached(priority: .utility) {
                        try AIHistoryStore.saveImage(
                            originalURL: originalURL,
                            action: action,
                            prompt: prompt,
                            imageData: imageData,
                            inputSource: inputSource,
                            inputByteCount: inputByteCount
                        )
                    }.value
                    guard !Task.isCancelled,
                          self.sessionCoordinator.isCurrent(aiTaskID, for: .ai),
                          self.currentAsset?.id == assetID else {
                        return
                    }
                    self.aiResultText = "AI 编辑结果已保存为独立版本，不会覆盖原图。"
                    self.aiHistory.insert(entry, at: 0)
                    self.statusMessage = "AI 编辑完成，结果已加入历史。"
                }
            } catch {
                guard !Task.isCancelled,
                      self.sessionCoordinator.isCurrent(aiTaskID, for: .ai),
                      self.currentAsset?.id == assetID else {
                    return
                }
                self.statusMessage = "AI 处理失败：\(error.localizedDescription)"
            }
        }
        sessionCoordinator.track(aiTask, for: .ai)
    }

    func selectAIProvider(_ provider: AIProviderKind) {
        guard selectedAIProvider != provider else {
            aiAPIKeyConfigured = KeychainStore.hasAPIKey(for: provider)
            return
        }

        aiConnectionTask?.cancel()
        isAITestingConnection = false
        selectedAIProvider = provider
        provider.saveAsSelected()
        let configuration = AIProviderConfiguration.load(for: provider)
        aiModel = configuration.model
        aiBaseURL = configuration.baseURL
        aiAPIKeyConfigured = KeychainStore.hasAPIKey(for: provider)
    }

    func saveAISettings(
        provider: AIProviderKind,
        apiKey: String,
        model: String,
        baseURL: String
    ) {
        do {
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                try KeychainStore.saveAPIKey(trimmedKey, for: provider)
            }

            let configuration = AIProviderConfiguration(
                provider: provider,
                model: model,
                baseURL: baseURL
            )
            guard AIEndpointPolicy.isAllowed(configuration.baseURL) else {
                statusMessage = "\(provider.displayName) API 地址必须使用 HTTPS；仅允许 localhost 本地接口使用 HTTP。"
                return
            }
            configuration.save()
            if provider == .openAI {
                OpenAISettings(model: configuration.model).save()
            }

            if selectedAIProvider != provider {
                selectedAIProvider = provider
                provider.saveAsSelected()
            }
            aiModel = configuration.model
            aiBaseURL = configuration.baseURL
            aiAPIKeyConfigured = KeychainStore.hasAPIKey(for: provider)
            statusMessage = "\(provider.displayName) 设置已保存。"
        } catch {
            statusMessage = "无法保存 \(provider.displayName) 设置：\(error.localizedDescription)"
        }
    }

    func removeAIAPIKey() {
        do {
            try KeychainStore.deleteAPIKey(for: selectedAIProvider)
            aiAPIKeyConfigured = false
            statusMessage = "\(selectedAIProvider.displayName) API Key 已从钥匙串删除。"
        } catch {
            statusMessage = "无法删除 \(selectedAIProvider.displayName) API Key：\(error.localizedDescription)"
        }
    }

    func testAIConnection() {
        guard !isAITestingConnection else {
            return
        }

        let provider = selectedAIProvider
        let configuration = AIProviderConfiguration(
            provider: provider,
            model: aiModel,
            baseURL: aiBaseURL
        )
        let apiKey = KeychainStore.loadAPIKey(for: provider)
        aiConnectionTask?.cancel()
        isAITestingConnection = true
        statusMessage = "正在测试 " + provider.displayName + " 连接…"

        let task = Task { [weak self] in
            defer {
                self?.isAITestingConnection = false
            }
            do {
                try await AIConnectionTester.test(
                    configuration: configuration,
                    apiKey: apiKey
                )
                guard !Task.isCancelled,
                      let self,
                      self.selectedAIProvider == provider else {
                    return
                }
                self.statusMessage = "\(provider.displayName) 连接成功。"
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.selectedAIProvider == provider else {
                    return
                }
                self.statusMessage = "\(provider.displayName) 连接失败：\(error.localizedDescription)"
            }
        }
        aiConnectionTask = task
    }

    func clearAIHistory() {
        do {
            try AIHistoryStore.clearAll()
            aiHistory = []
            aiResultText = ""
            statusMessage = "AI 历史已清空。"
        } catch {
            statusMessage = "无法清空 AI 历史：\(error.localizedDescription)"
        }
    }

    func deleteAIHistoryEntry(_ entry: AIHistoryEntry) {
        guard let asset = currentAsset else {
            return
        }
        do {
            try AIHistoryStore.delete(entry, originalURL: asset.url)
            aiHistory = AIHistoryStore.load(
                originalURL: asset.url,
                retention: aiPrivacyPreferences.historyRetention
            )
            statusMessage = "已删除一条 AI 历史。"
        } catch {
            statusMessage = "无法删除 AI 历史：\(error.localizedDescription)"
        }
    }

    private func makeAIProvider(
        kind: AIProviderKind,
        model: String,
        baseURL: String,
        apiKey: String?
    ) -> any AIAnalysisProvider {
        switch kind {
        case .openAI:
            return OpenAIAPIProvider(model: model, apiKey: apiKey)
        case .deepSeek:
            return OpenAICompatibleAPIProvider(
                model: model,
                baseURL: baseURL,
                apiKey: apiKey,
                provider: .deepSeek
            )
        case .anthropic:
            return AnthropicAPIProvider(model: model, baseURL: baseURL, apiKey: apiKey)
        case .gemini:
            return GeminiAPIProvider(model: model, baseURL: baseURL, apiKey: apiKey)
        case .openAICompatible:
            return OpenAICompatibleAPIProvider(model: model, baseURL: baseURL, apiKey: apiKey)
        }
    }

    func clearStatus() {
        statusMessage = nil
    }

    func exportCurrent(
        format: ImageExportFormat,
        options: ImageExportOptions
    ) {
        guard let asset = currentAsset else {
            return
        }

        let baseName = asset.url.deletingPathExtension().lastPathComponent
        let defaultName = "\(baseName).\(format.fileExtension)"
        guard let destinationURL = FileOperations.chooseSaveLocation(defaultName: defaultName) else {
            return
        }

        statusMessage = "正在导出 \(asset.filename)…"
        let sourceURL = asset.url
        let recipe = editRecipe
        PerformanceLog.event("ExportRequested")
        let exportTaskID = sessionCoordinator.start(.export)
        let exportTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try ImageExportService.export(
                        sourceURL: sourceURL,
                        destinationURL: destinationURL,
                        format: format,
                        options: options,
                        recipe: recipe
                    )
                }
            }.value

            guard let self,
                  self.sessionCoordinator.isCurrent(exportTaskID, for: .export) else {
                return
            }
            switch result {
            case .success:
                PerformanceLog.event("ExportCompleted")
                self.statusMessage = "已导出 \(destinationURL.lastPathComponent)。"
            case let .failure(error):
                self.statusMessage = "导出失败：\(error.localizedDescription)"
            }
        }
        sessionCoordinator.track(exportTask, for: .export)
    }

    func batchConvert(
        format: ImageExportFormat,
        options: ImageExportOptions
    ) {
        guard !assets.isEmpty else {
            return
        }
        guard let destinationDirectory = FileOperations.chooseDirectory(title: "选择批量导出文件夹") else {
            return
        }

        let assetsToExport = assets
        let recipe = editRecipe
        statusMessage = "正在批量转换 \(assetsToExport.count) 张图片…"
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try ImageExportService.batchExport(
                        assets: assetsToExport,
                        destinationDirectory: destinationDirectory,
                        format: format,
                        options: options,
                        recipe: recipe
                    )
                }
            }.value

            guard let self else {
                return
            }
            switch result {
            case let .success(count):
                self.statusMessage = "已批量转换 \(count) 张图片。"
            case let .failure(error):
                self.statusMessage = "批量转换失败：\(error.localizedDescription)"
            }
        }
    }

    func batchRename(options: BatchRenameOptions) {
        guard assets.count > 1 else {
            statusMessage = "至少需要两张图片才能批量重命名。"
            return
        }

        let assetsToRename = assets
        statusMessage = "正在批量重命名 \(assetsToRename.count) 张图片…"
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try FileBatchService.rename(assets: assetsToRename, options: options)
                }
            }.value

            guard let self else {
                return
            }
            switch result {
            case let .success(urls):
                self.statusMessage = "已重命名 \(urls.count) 张图片。"
                self.refreshDirectory()
            case let .failure(error):
                self.statusMessage = "批量重命名失败：\(error.localizedDescription)"
            }
        }
    }

    func refreshDirectory() {
        guard let directory = directoryURL else {
            return
        }

        startDirectoryScan(
            directory: directory,
            preservingAsset: currentAsset,
            selectedAssetID: currentAsset?.id,
            fallbackIndex: currentIndex
        )
    }

    func setShortcut(_ action: ShortcutAction, value: String) {
        var updated = shortcuts
        switch action {
        case .previous:
            updated.previous = value
        case .next:
            updated.next = value
        case .rotate:
            updated.rotate = value
        case .inspector:
            updated.inspector = value
        case .fullscreen:
            updated.fullscreen = value
        }
        shortcuts = updated.sanitized()
        shortcuts.save()
    }

    func resetShortcuts() {
        shortcuts = .defaults
        shortcuts.save()
    }

    func setLocalToolPermission(
        _ scope: LocalToolPermissionScope,
        allowed: Bool
    ) {
        localToolPermissions.set(allowed, for: scope)
        localToolPermissions.save()
        statusMessage = allowed
            ? "已允许本地工具：\(scope.displayName)。"
            : "已禁止本地工具：\(scope.displayName)。"
    }

    func handleLocalToolURL(_ url: URL) {
        guard let request = LocalToolRequest(url: url) else {
            statusMessage = "无法识别本地工具请求。"
            return
        }

        if request.tool == .openImage {
            guard localToolPermissions.allows(request.tool) else {
                publishLocalToolResponse(
                    .failure(
                        for: request.tool,
                        message: "未授予“\(request.tool.displayName)”权限。"
                    )
                )
                return
            }
            queuedLocalToolRequests.append(request)
            presentNextLocalToolRequestIfNeeded()
            return
        }

        publishLocalToolResponse(executeLocalTool(request))
    }

    func confirmLocalToolOpenRequest() {
        guard let request = pendingLocalToolRequest else {
            isShowingLocalToolConfirmation = false
            return
        }
        pendingLocalToolRequest = nil
        isShowingLocalToolConfirmation = false
        publishLocalToolResponse(executeLocalTool(request))
        presentNextLocalToolRequestIfNeeded()
    }

    func rejectLocalToolOpenRequest() {
        guard let request = pendingLocalToolRequest else {
            isShowingLocalToolConfirmation = false
            return
        }
        pendingLocalToolRequest = nil
        isShowingLocalToolConfirmation = false
        publishLocalToolResponse(
            .failure(for: request.tool, message: "用户拒绝了打开图片请求。")
        )
        presentNextLocalToolRequestIfNeeded()
    }

    private func presentNextLocalToolRequestIfNeeded() {
        guard !isShowingLocalToolConfirmation,
              pendingLocalToolRequest == nil,
              !queuedLocalToolRequests.isEmpty else {
            return
        }
        pendingLocalToolRequest = queuedLocalToolRequests.removeFirst()
        isShowingLocalToolConfirmation = true
    }

    private func publishLocalToolResponse(_ response: LocalToolResponse) {
        if response.ok {
            statusMessage = response.message
        } else {
            statusMessage = "本地工具请求未执行：\(response.message)"
        }
        NotificationCenter.default.post(
            name: .imageViewerLocalToolResponse,
            object: response
        )
    }

    func executeLocalTool(_ request: LocalToolRequest) -> LocalToolResponse {
        guard localToolPermissions.allows(request.tool) else {
            return .failure(
                for: request.tool,
                message: "未授予“\(request.tool.displayName)”权限。"
            )
        }

        switch request.tool {
        case .getCurrentImage:
            guard let asset = currentAsset else {
                return .failure(for: request.tool, message: "当前没有打开的图片。")
            }
            return .success(
                for: request.tool,
                message: "已返回当前图片信息。",
                image: LocalToolImageSummary(asset: asset)
            )

        case .getImageMetadata:
            guard let asset = currentAsset else {
                return .failure(for: request.tool, message: "当前没有打开的图片。")
            }
            let metadata = self.metadata ?? ImageMetadataReader.read(asset: asset)
            return .success(
                for: request.tool,
                message: "已返回当前图片元数据。",
                image: LocalToolImageSummary(asset: asset),
                metadata: metadata.localToolFields
            )

        case .listFolderImages:
            guard currentAsset != nil else {
                return .failure(for: request.tool, message: "当前没有打开的文件夹。")
            }
            return .success(
                for: request.tool,
                message: "已返回当前文件夹中的图片列表。",
                images: assets.map(LocalToolImageSummary.init(asset:))
            )

        case .openImage:
            guard let path = request.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                return .failure(for: request.tool, message: "缺少要打开的图片路径。")
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path),
                  ImageAsset.isSupportedImage(url) else {
                return .failure(for: request.tool, message: "路径不是受支持的图片文件。")
            }
            let asset = ImageAsset(url: url)
            open(url: url)
            return .success(
                for: request.tool,
                message: "已请求打开 \(asset.filename)。",
                image: LocalToolImageSummary(asset: asset)
            )
        }
    }

    private func move(by offset: Int) {
        guard !assets.isEmpty else {
            return
        }
        let newIndex = (currentIndex + offset + assets.count) % assets.count
        guard newIndex != currentIndex else {
            return
        }
        PerformanceLog.event("NavigateImage")
        currentIndex = newIndex
        resetViewState()
        loadCurrentImage()
        prefetchNeighbors(direction: offset < 0 ? .backward : .forward)
    }

    private func resetViewState() {
        canvasMode = .fit
        zoomFactor = 1
        isShowingOriginalPreview = false
        isCropSelectionMode = false
        cropSelection = nil
        histogram = nil
        pixelSampleStore.update(nil)
        isInspectionLoading = false
        sessionCoordinator.cancel(.inspection)
        rotationDegrees = 0
        isFlippedHorizontally = false
        editRecipe = .empty
        editHistory = EditHistory()
        adjustments = .default
        metadata = nil
        aiSelection = nil
        isAISelectionMode = false
        aiResultText = ""
    }

    private func scanDirectory(seed: ImageAsset) {
        let directory = seed.url.deletingLastPathComponent()
        watchDirectory(directory)
        startDirectoryScan(
            directory: directory,
            preservingAsset: seed,
            selectedAssetID: seed.id,
            fallbackIndex: 0
        )
    }

    private func startDirectoryScan(
        directory: URL,
        preservingAsset: ImageAsset?,
        selectedAssetID: String?,
        fallbackIndex: Int
    ) {
        sessionCoordinator.cancel(.scan)
        let directorySession = directorySession
        let scanTaskID = sessionCoordinator.start(.scan)
        let scanTask = Task { [weak self] in
            let stream = await directorySession.start(
                directoryURL: directory,
                batchSize: 128
            )
            var scannedAssets: [ImageAsset] = []

            for await batch in stream {
                guard !Task.isCancelled,
                      let self,
                      self.sessionCoordinator.isCurrent(scanTaskID, for: .scan),
                      self.currentAsset?.url.deletingLastPathComponent() == directory else {
                    return
                }

                scannedAssets.append(contentsOf: batch.assets)
                let visibleAssets = self.sortedDirectoryAssets(
                    scannedAssets,
                    preserving: preservingAsset,
                    includePreservedAsset: !batch.isComplete
                )
                self.applyDirectoryAssets(
                    visibleAssets,
                    selectedAssetID: selectedAssetID,
                    fallbackIndex: fallbackIndex,
                    reloadCurrentImage: batch.isComplete
                )

                if batch.isComplete {
                    self.prefetchNeighbors(direction: .forward)
                }
            }
        }
        sessionCoordinator.track(scanTask, for: .scan)
    }

    private func applyDirectoryAssets(
        _ newAssets: [ImageAsset],
        selectedAssetID: String?,
        fallbackIndex: Int,
        reloadCurrentImage: Bool
    ) {
        let previousAsset = currentAsset
        assets = newAssets

        if let selectedAssetID,
           let selectedIndex = newAssets.firstIndex(where: { $0.id == selectedAssetID }) {
            currentIndex = selectedIndex
        } else if newAssets.isEmpty {
            currentIndex = 0
        } else {
            currentIndex = min(fallbackIndex, newAssets.count - 1)
        }

        guard reloadCurrentImage else {
            return
        }
        guard let currentAsset else {
            currentImage = nil
            currentDisplayImage = nil
            metadata = nil
            currentAnimation?.close()
            currentAnimation = nil
            animatedFrameStore.update(nil)
            currentMotionPhoto = nil
            sessionCoordinator.cancel(.animation)
            sessionCoordinator.cancel(.motionPhoto)
            sessionCoordinator.cancel(.image)
            aiHistory = []
            aiResultText = ""
            isLoading = false
            return
        }
        guard previousAsset != currentAsset || self.currentImage == nil else {
            return
        }

        resetViewState()
        loadCurrentImage()
    }

    private func sortedDirectoryAssets(
        _ scannedAssets: [ImageAsset],
        preserving preservedAsset: ImageAsset?,
        includePreservedAsset: Bool
    ) -> [ImageAsset] {
        var combined = scannedAssets
        if includePreservedAsset,
           let preservedAsset,
           !combined.contains(where: { $0.id == preservedAsset.id }) {
            let insertionIndex = combined.firstIndex {
                let comparison = preservedAsset.filename.localizedStandardCompare($0.filename)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
                return preservedAsset.id < $0.id
            } ?? combined.endIndex
            combined.insert(preservedAsset, at: insertionIndex)
        }
        return combined
    }

    private func watchDirectory(_ directory: URL) {
        directoryWatcher?.cancel()
        let watcher = DirectoryWatcher(directoryURL: directory) { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.scheduleDirectoryRefresh()
            }
        }
        directoryWatcher = watcher
        watcher.start()
    }

    private func scheduleDirectoryRefresh() {
        directoryRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshDirectory()
        }
        directoryRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.2,
            execute: workItem
        )
    }

    private func loadCurrentImage() {
        let imageSession = sessionCoordinator.beginImageSession()
        currentImageSession = imageSession
        currentAnimation?.close()
        currentAnimation = nil
        animatedFrameStore.update(nil)
        currentMotionPhoto = nil

        guard let asset = currentAsset else {
            currentImage = nil
            metadata = nil
            aiHistory = []
            aiResultText = ""
            isLoading = false
            return
        }

        let assetID = asset.id
        aiHistory = AIHistoryStore.load(
            originalURL: asset.url,
            retention: aiPrivacyPreferences.historyRetention
        )
        aiResultText = ""
        let animated = isAnimated(asset)
        let maxPixelSize: Int?
        let sourcePixelSize = ImageTilePixelSize(
            width: asset.pixelWidth,
            height: asset.pixelHeight
        )
        if canvasMode == .actualSize,
           sourcePixelSize.isValid,
           !sourcePixelSize.isLargeImage {
            maxPixelSize = max(asset.pixelWidth, asset.pixelHeight)
        } else {
            // Keep the first visible frame bounded for very large originals.
            // The canvas promotes this proxy to source-backed tiles after the
            // interaction settles, so panning never has to move one massive
            // full-resolution texture through the interactive layer.
            maxPixelSize = ImageTilePixelSize.interactiveMaxPixelSize
        }

        currentImage = nil
        isLoading = true
        let imageTask = Task { [weak self] in
            let animationSession = animated ? await AnimatedImageSession.open(
                url: asset.url,
                maxPixelSize: min(
                    maxPixelSize ?? ImageTilePixelSize.interactiveMaxPixelSize,
                    ImageTilePixelSize.interactiveMaxPixelSize
                ),
                windowSize: 1,
                byteBudget: 64 * 1024 * 1024
            ) : nil
            guard !Task.isCancelled,
                  let self,
                  self.sessionCoordinator.isCurrent(imageSession) else {
                animationSession?.close()
                return
            }
            guard self.currentAsset?.id == assetID else {
                animationSession?.close()
                return
            }

            if let animationSession,
               animationSession.frameCount > 1 {
                let firstFrame = await animationSession.image(at: 0)
                guard !Task.isCancelled,
                      self.sessionCoordinator.isCurrent(imageSession),
                      self.currentAsset?.id == assetID else {
                    animationSession.close()
                    return
                }
                if let firstFrame {
                    self.currentAnimation = animationSession
                    self.animatedFrameStore.update(firstFrame)
                    self.currentImage = firstFrame
                    self.scheduleInspection(includeAnimatedFrame: true)
                    PerformanceLog.event("FirstVisibleFrame")
                    self.startAnimation(animationSession, assetID: assetID)
                    self.isLoading = false
                    return
                }
                animationSession.close()
            }

            let decodedImage = await DecodedImageCache.shared.image(
                for: asset.url,
                maxPixelSize: maxPixelSize
            )
            guard !Task.isCancelled,
                  self.sessionCoordinator.isCurrent(imageSession),
                  self.currentAsset?.id == assetID else {
                return
            }
            self.currentImage = decodedImage
            if decodedImage != nil {
                PerformanceLog.event("FirstVisibleFrame")
            }
            self.isLoading = false
        }
        sessionCoordinator.track(imageTask, for: .image)

        let motionPhotoTaskID = sessionCoordinator.start(.motionPhoto)
        let motionPhotoTask = Task { [weak self] in
            guard let self else {
                return
            }
            let info = try? await self.motionPhotoDetector.detect(url: asset.url)
            guard !Task.isCancelled,
                  self.sessionCoordinator.isCurrent(imageSession),
                  self.sessionCoordinator.isCurrent(motionPhotoTaskID, for: .motionPhoto),
                  self.currentAsset?.id == assetID else {
                return
            }
            self.currentMotionPhoto = info ?? nil
        }
        sessionCoordinator.track(motionPhotoTask, for: .motionPhoto)

        let metadataTask = Task { [weak self] in
            let imageMetadata = await Task.detached(priority: .utility) {
                ImageMetadataReader.read(asset: asset)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.sessionCoordinator.isCurrent(imageSession),
                  self.currentAsset?.id == assetID else {
                return
            }
            self.metadata = imageMetadata
        }
        sessionCoordinator.track(metadataTask, for: .metadata)
    }

    private func prefetchNeighbors(direction: ImagePrefetchDirection) {
        guard assets.count > 1 else {
            return
        }

        let offsets: [Int]
        switch direction {
        case .forward:
            offsets = [1, 2]
        case .backward:
            offsets = [-1, -2]
        }
        let urls = offsets.map { offset in
            assets[(currentIndex + offset + assets.count) % assets.count].url
        }
        DecodedImageCache.shared.prefetch(
            urls: urls,
            maxPixelSize: 2048,
            direction: direction
        )
    }

    private func scheduleAdjustedImage() {
        sessionCoordinator.cancel(.adjustment)

        guard let sourceImage = currentImage else {
            currentDisplayImage = nil
            return
        }
        guard let imageSession = currentImageSession else {
            currentDisplayImage = sourceImage
            return
        }

        let requestedRecipe = editRecipe
        guard !requestedRecipe.isEmpty else {
            currentDisplayImage = sourceImage
            return
        }

        let sourceID = ObjectIdentifier(sourceImage)
        let adjustmentTaskID = sessionCoordinator.start(.adjustment)
        let adjustmentTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 24_000_000)
            guard !Task.isCancelled else {
                return
            }

            let previewImage = await Task.detached(priority: .userInitiated) {
                ImageRecipeRenderer.renderPreviewPixels(
                    image: sourceImage,
                    recipe: requestedRecipe,
                    quality: .interactive
                ) ?? sourceImage
            }.value

            guard !Task.isCancelled,
                  let self,
                  self.sessionCoordinator.isCurrent(imageSession),
                  self.sessionCoordinator.isCurrent(adjustmentTaskID, for: .adjustment) else {
                return
            }
            guard self.currentImage.map(ObjectIdentifier.init) == sourceID,
                  self.editRecipe == requestedRecipe else {
                return
            }

            self.currentDisplayImage = previewImage
            PerformanceLog.event("AdjustmentPreviewCompleted")

            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled,
                  self.sessionCoordinator.isCurrent(imageSession),
                  self.sessionCoordinator.isCurrent(adjustmentTaskID, for: .adjustment),
                  self.currentImage.map(ObjectIdentifier.init) == sourceID,
                  self.editRecipe == requestedRecipe else {
                return
            }

            let settledImage = await Task.detached(priority: .userInitiated) {
                ImageRecipeRenderer.renderPreviewPixels(
                    image: sourceImage,
                    recipe: requestedRecipe,
                    quality: .settled
                ) ?? sourceImage
            }.value

            guard !Task.isCancelled,
                  self.sessionCoordinator.isCurrent(imageSession),
                  self.sessionCoordinator.isCurrent(adjustmentTaskID, for: .adjustment),
                  self.currentImage.map(ObjectIdentifier.init) == sourceID,
                  self.editRecipe == requestedRecipe else {
                return
            }

            self.currentDisplayImage = settledImage
            PerformanceLog.event("AdjustmentCompleted")
        }
        sessionCoordinator.track(adjustmentTask, for: .adjustment)
    }

    private func scheduleInspection(includeAnimatedFrame: Bool = false) {
        guard includeAnimatedFrame || currentAnimation == nil else {
            return
        }
        sessionCoordinator.cancel(.inspection)
        let image = isShowingOriginalPreview
            ? currentImage
            : currentDisplayImage ?? currentImage
        guard let image,
              let imageSession = currentImageSession else {
            histogram = nil
            isInspectionLoading = false
            return
        }

        let imageID = ObjectIdentifier(image)
        let inspectionTaskID = sessionCoordinator.start(.inspection)
        isInspectionLoading = true
        let task = Task { [weak self] in
            let computed = await Task.detached(priority: .utility) {
                ImageHistogramService.compute(image: image)
            }.value

            guard !Task.isCancelled,
                  let self,
                  self.sessionCoordinator.isCurrent(imageSession),
                  self.sessionCoordinator.isCurrent(inspectionTaskID, for: .inspection),
                  self.currentImage.map(ObjectIdentifier.init) == imageID
            else {
                return
            }
            self.histogram = computed
            self.isInspectionLoading = false
        }
        sessionCoordinator.track(task, for: .inspection)
    }

    private func recordEditRecipe(
        _ recipe: EditRecipe,
        coalescingKey: String? = nil
    ) {
        editHistory.apply(recipe, coalescingKey: coalescingKey)
        applyEditRecipe(recipe)
    }

    private func applyEditRecipe(_ recipe: EditRecipe) {
        editRecipe = recipe
        adjustments = recipe.imageAdjustments
        rotationDegrees = recipe.rotationDegrees
        isFlippedHorizontally = recipe.isFlippedHorizontally
        cropSelection = recipe.cropRect?.cgRect
    }

    private func recipeForCurrentEdits(
        adjustments: ImageAdjustments,
        rotationDegrees: Double,
        isFlippedHorizontally: Bool
    ) -> EditRecipe {
        EditRecipe(
            adjustments: adjustments,
            rotationDegrees: rotationDegrees,
            isFlippedHorizontally: isFlippedHorizontally,
            cropRect: cropSelection.map(EditCropRect.init(rect:))
        )
    }

}
