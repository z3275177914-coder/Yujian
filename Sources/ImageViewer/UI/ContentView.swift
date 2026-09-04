import AppKit
import ImageViewerCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: @preconcurrency View {
    @EnvironmentObject private var model: ImageViewerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let initialURL: URL?
    private let initialToolURLs: [URL]
    @State private var isCanvasHovered = true
    @State private var sidebarVisible = true
    @State private var inspectorVisible = true
    @State private var zoomInput = "100"
    @FocusState private var isZoomInputFocused: Bool

    init(initialURL: URL? = nil, initialToolURLs: [URL] = []) {
        self.initialURL = initialURL
        self.initialToolURLs = initialToolURLs
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                if sidebarVisible {
                    ZStack(alignment: .trailing) {
                        ThumbnailSidebarView()

                        PanelCollapseHandle(
                            title: "收起浏览侧栏",
                            systemImage: "chevron.left"
                        ) {
                            toggleSidebar()
                        }
                        // Keep a generous, centered hit target straddling the
                        // panel edge. The visual capsule stays compact while
                        // fast clicks do not depend on landing on its icon.
                        .offset(x: 32)
                        .zIndex(10)
                    }
                    .frame(width: 220)
                    .frame(maxHeight: .infinity)
                    .zIndex(2)
                    Divider()
                } else {
                    CollapsedPanelRail(
                        edge: .leading,
                        title: "展开浏览侧栏"
                    ) {
                        toggleSidebar()
                    }
                    .zIndex(4)
                }

                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if inspectorVisible {
                    Divider()
                    ZStack(alignment: .leading) {
                        InspectorView()
                            .environmentObject(model.pixelSampleStore)

                        PanelCollapseHandle(
                            title: "收起检查器",
                            systemImage: "chevron.right"
                        ) {
                            toggleInspector()
                        }
                        .offset(x: -32)
                        .zIndex(10)
                    }
                    .frame(width: 310)
                    .frame(maxHeight: .infinity)
                    .zIndex(2)
                } else {
                    CollapsedPanelRail(
                        edge: .trailing,
                        title: "展开检查器"
                    ) {
                        toggleInspector()
                    }
                    .zIndex(4)
                }
            }
            // Panel visibility changes are intentionally committed as one
            // layout transaction. Animating the whole HStack causes the
            // canvas to resize repeatedly, which in turn invalidates tiles
            // and makes both panel collapse and scrolling feel sticky.
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = reduceMotion
            }

            if isCanvasHovered, model.currentImage != nil {
                bottomControls
                    .padding(.bottom, 18)
                    .transition(.opacity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(model.currentAsset?.filename ?? "玉鉴")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    toggleSidebar()
                } label: {
                    Label("侧栏", systemImage: "sidebar.left")
                }
                .accessibilityIdentifier("sidebar-toggle")
                .accessibilityValue(sidebarVisible ? "已展开" : "已收起")
                .accessibilityHint("点击切换浏览侧栏")
                .help("显示或隐藏侧栏")

                Button {
                    model.previousImage()
                } label: {
                    Label("上一张", systemImage: "chevron.left")
                }
                .accessibilityIdentifier("previous-image")
                .disabled(model.assets.isEmpty)

                Button {
                    model.nextImage()
                } label: {
                    Label("下一张", systemImage: "chevron.right")
                }
                .accessibilityIdentifier("next-image")
                .disabled(model.assets.isEmpty)
            }

            ToolbarItemGroup(placement: .principal) {
                Button {
                    model.zoomOut()
                } label: {
                    Label("缩小", systemImage: "minus.magnifyingglass")
                }
                .accessibilityIdentifier("zoom-out")
                .disabled(model.currentAsset == nil)

                Text(model.canvasMode.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48)

                zoomInputField

                Button {
                    model.zoomIn()
                } label: {
                    Label("放大", systemImage: "plus.magnifyingglass")
                }
                .accessibilityIdentifier("zoom-in")
                .disabled(model.currentAsset == nil)

                Button {
                    model.fitImage()
                } label: {
                    Label("适应窗口", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityIdentifier("fit-image")
                .disabled(model.currentAsset == nil)

                Button {
                    model.actualSize()
                } label: {
                    Label("实际大小", systemImage: "1.circle")
                }
                .accessibilityIdentifier("actual-size")
                .disabled(model.currentAsset == nil)

                Button {
                    model.infiniteCanvas()
                } label: {
                    Label("无限画布", systemImage: "infinity")
                }
                .accessibilityIdentifier("infinite-canvas")
                .disabled(model.currentAsset == nil)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.undoEdits()
                } label: {
                    Label("撤销编辑", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndoEdits)
                .help("撤销上一次编辑")

                Button {
                    model.redoEdits()
                } label: {
                    Label("重做编辑", systemImage: "arrow.uturn.forward")
                }
                .disabled(!model.canRedoEdits)
                .help("重做上一次编辑")

                Button {
                    model.rotateRight()
                } label: {
                    Label("旋转", systemImage: "rotate.right")
                }
                .disabled(model.currentAsset == nil)

                Button {
                    model.toggleOriginalPreview()
                } label: {
                    Label(
                        model.isShowingOriginalPreview ? "显示编辑结果" : "按住查看原图",
                        systemImage: model.isShowingOriginalPreview ? "photo" : "rectangle.on.rectangle"
                    )
                }
                .disabled(!model.hasPreviewEdits)
                .help("在原图和编辑结果之间切换")

                Button {
                    toggleInspector()
                } label: {
                    Label("检查器", systemImage: "info.circle")
                }
                .help("显示或隐藏检查器")
                .accessibilityIdentifier("inspector-toggle")
                .accessibilityValue(inspectorVisible ? "已展开" : "已收起")
                .accessibilityHint("点击切换检查器")

                Button {
                    showInspector()
                    model.showAI()
                } label: {
                    Label("询问 AI", systemImage: "sparkles")
                }
                .help("打开 AI 工作区")
                .disabled(model.currentAsset == nil)

                Menu {
                    Button("打开图片…", systemImage: "folder") {
                        model.openPanel()
                    }
                    SettingsLink {
                        Label("设置…", systemImage: "gear")
                    }
                    Divider()
                    Button("在访达中显示", systemImage: "finder") {
                        model.revealInFinder()
                    }
                    .disabled(model.currentAsset == nil)
                    Button("另存为…", systemImage: "square.and.arrow.down") {
                        model.saveAs()
                    }
                    .disabled(model.currentAsset == nil)
                    Button("转换 / 调整大小…", systemImage: "arrow.triangle.2.circlepath") {
                        model.isShowingExportPanel = true
                    }
                    .disabled(model.currentAsset == nil)
                    Button("批量转换…", systemImage: "square.stack.3d.up") {
                        model.isShowingBatchConvertPanel = true
                    }
                    .disabled(model.assets.isEmpty)
                    Button("批量重命名…", systemImage: "character.cursor.ibeam") {
                        model.isShowingBatchRenamePanel = true
                    }
                    .disabled(model.assets.count < 2)
                    Button("移到废纸篓", systemImage: "trash") {
                        model.moveCurrentToTrash()
                    }
                    .disabled(model.currentAsset == nil)
                    Divider()
                    Button("水平翻转", systemImage: "arrow.left.and.right") {
                        model.toggleFlip()
                    }
                    .disabled(model.currentAsset == nil)
                    Divider()
                    Button("适应窗口", systemImage: "arrow.up.left.and.arrow.down.right") {
                        model.fitImage()
                    }
                    .disabled(model.currentAsset == nil)
                    Button("无限画布", systemImage: "infinity") {
                        model.infiniteCanvas()
                    }
                    .disabled(model.currentAsset == nil)
                    Button("实际大小", systemImage: "1.circle") {
                        model.actualSize()
                    }
                    .disabled(model.currentAsset == nil)
                    Button("进入全屏", systemImage: "arrow.up.left.and.arrow.down.right") {
                        model.toggleFullScreen()
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
        }
        .overlay(alignment: .top) {
            if let statusMessage = model.statusMessage {
                StatusBanner(message: statusMessage) {
                    guard model.statusMessage == statusMessage else {
                        return
                    }
                    model.clearStatus()
                }
                .padding(.top, 12)
                .task(id: statusMessage) {
                    do {
                        try await Task.sleep(
                            nanoseconds: StatusBanner.autoDismissNanoseconds
                        )
                    } catch {
                        return
                    }
                    guard !Task.isCancelled,
                          model.statusMessage == statusMessage else {
                        return
                    }
                    model.clearStatus()
                }
            }
        }
        .onHover { isCanvasHovered = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .imageViewerOpenURLs)) { notification in
            guard let urls = notification.object as? [URL], let url = urls.first else {
                return
            }
            model.open(url: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageViewerLocalToolURLs)) { notification in
            guard let urls = notification.object as? [URL] else {
                return
            }
            urls.forEach { model.handleLocalToolURL($0) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageViewerToggleSidebar)) { _ in
            toggleSidebar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageViewerToggleInspector)) { _ in
            toggleInspector()
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageViewerShowAI)) { _ in
            showInspector()
            model.showAI()
        }
        .onChange(of: model.zoomFactor) { _, _ in
            if !isZoomInputFocused {
                zoomInput = model.zoomPercentageInput
            }
        }
        .onChange(of: isZoomInputFocused) { _, isFocused in
            if !isFocused {
                commitZoomInput()
            }
        }
        .sheet(isPresented: $model.isShowingExportPanel) {
            ExportPanelView(isBatch: false)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isShowingBatchConvertPanel) {
            ExportPanelView(isBatch: true)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isShowingBatchRenamePanel) {
            BatchRenamePanelView()
                .environmentObject(model)
        }
        .alert("云端 AI 隐私提示", isPresented: $model.isShowingAIPrivacyNotice) {
            Button("继续并同意") {
                model.acceptCloudAIPrivacyNotice()
            }
            Button("取消", role: .cancel) {
                model.declineCloudAIPrivacyNotice()
            }
        } message: {
            Text("继续后，所选图片内容和提示词可能会离开本机：云端 AI 请求会发送给当前接口，ChatGPT 交接会写入系统剪贴板并由你在聊天框提交。云端服务的数据处理由对应服务商负责；本机 AI 历史可在设置中清理。")
        }
        .alert("移到废纸篓？", isPresented: $model.isShowingTrashConfirmation) {
            Button("移到废纸篓", role: .destructive) {
                model.confirmMoveCurrentToTrash()
            }
            Button("取消", role: .cancel) {
                model.cancelMoveCurrentToTrash()
            }
        } message: {
            Text("将文件“" + model.trashConfirmationFilename + "”移到 macOS 废纸篓，可在废纸篓中恢复。")
        }
        .alert("外部工具请求打开图片", isPresented: $model.isShowingLocalToolConfirmation) {
            Button("允许并打开") {
                model.confirmLocalToolOpenRequest()
            }
            Button("拒绝", role: .cancel) {
                model.rejectLocalToolOpenRequest()
            }
        } message: {
            Text("本地工具请求打开：\n" + model.localToolConfirmationPath + "\n\n仅在你确认来源可信时允许。")
        }
        .task {
            zoomInput = model.zoomPercentageInput
            guard let initialURL else {
                initialToolURLs.forEach { model.handleLocalToolURL($0) }
                return
            }
            model.open(url: initialURL)
            initialToolURLs.forEach { model.handleLocalToolURL($0) }
        }
    }

    @ViewBuilder
    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            ImageCanvasView(
                image: model.isShowingOriginalPreview
                    ? model.currentImage
                    : model.currentDisplayImage ?? model.currentImage,
                sourceURL: model.editRecipe.isEmpty && model.currentAnimation == nil
                    ? model.currentAsset?.url
                    : nil,
                sourcePixelSize: model.editRecipe.isEmpty && model.currentAnimation == nil
                    ? model.currentAsset.map {
                        CGSize(
                            width: CGFloat($0.pixelWidth),
                            height: CGFloat($0.pixelHeight)
                        )
                    }
                    : nil,
                animatedFrameStore: model.currentAnimation != nil && model.editRecipe.isEmpty
                    ? model.animatedFrameStore
                    : nil,
                motionPhoto: model.currentMotionPhoto
                    .flatMap { model.editRecipe.isEmpty ? $0 : nil },
                displayMode: $model.canvasMode,
                zoomFactor: $model.zoomFactor,
                mouseSensitivity: CGFloat(model.mouseSensitivity),
                rotationDegrees: model.rotationDegrees,
                isFlippedHorizontally: model.isFlippedHorizontally,
                shortcuts: model.shortcuts,
                isSelectionMode: model.isAISelectionMode,
                selection: model.aiSelection,
                isCropSelectionMode: model.isCropSelectionMode,
                cropSelection: model.cropSelection,
                onKeyAction: handleKeyAction,
                onDisplayModeChange: { model.setDisplayMode($0) },
                onZoomChange: { model.setZoomFactor($0) },
                onSelectionChange: { model.updateAISelection($0) },
                onCropSelectionChange: { model.updateCropSelection($0) },
                onPixelSampleChange: { model.samplePixel(at: $0) }
            )

            if model.currentMotionPhoto != nil,
               model.currentAnimation == nil,
               model.editRecipe.isEmpty {
                MotionPhotoBadge()
                    .padding(.top, 16)
                    .padding(.leading, 16)
                    .allowsHitTesting(false)
            }

            if model.currentImage == nil {
                EmptyViewerState(
                    isLoading: model.isLoading,
                    hasAsset: model.currentAsset != nil
                ) {
                    model.openPanel()
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else {
                return false
            }

            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }
                Task { @MainActor in
                    model.open(url: url)
                }
            }
            return true
        }
        .contextMenu {
            Button("复制图片", systemImage: "doc.on.doc") {
                model.copyCurrentImage()
            }
            .disabled(model.currentImage == nil)
            Button("撤销编辑", systemImage: "arrow.uturn.backward") {
                model.undoEdits()
            }
            .disabled(!model.canUndoEdits)
            Button("重做编辑", systemImage: "arrow.uturn.forward") {
                model.redoEdits()
            }
            .disabled(!model.canRedoEdits)
            Button("复制路径", systemImage: "link") {
                model.copyCurrentPath()
            }
            .disabled(model.currentAsset == nil)
            Divider()
            Button("在访达中显示", systemImage: "finder") {
                model.revealInFinder()
            }
            .disabled(model.currentAsset == nil)
            Button("移到废纸篓", systemImage: "trash") {
                model.moveCurrentToTrash()
            }
            .disabled(model.currentAsset == nil)
        }
    }

    private var bottomControls: some View {
        HStack(spacing: 8) {
            Button {
                model.previousImage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("上一张图片")

            Button {
                model.nextImage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("下一张图片")

            Divider()
                .frame(height: 18)

            Button {
                model.zoomOut()
            } label: {
                Image(systemName: "minus")
            }
            .help("缩小")

            zoomInputField

            Button {
                model.zoomIn()
            } label: {
                Image(systemName: "plus")
            }
            .help("放大")

            Button {
                model.fitImage()
            } label: {
                Text("适应窗口")
            }
            .help("适应窗口")

            Button {
                model.infiniteCanvas()
            } label: {
                Image(systemName: "infinity")
            }
            .help("无限画布")

            Button {
                model.rotateRight()
            } label: {
                Image(systemName: "rotate.right")
            }
            .help("向右旋转")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.96),
            in: Capsule()
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private var zoomInputField: some View {
        HStack(spacing: 2) {
            TextField("100", text: $zoomInput)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 42)
                .focused($isZoomInputFocused)
                .accessibilityIdentifier("zoom-percentage-input")
                .accessibilityLabel("缩放比例百分比")
                .accessibilityHint("输入大于 0 的百分比")
                .onSubmit {
                    commitZoomInput()
                }

            Text("%")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(
            Color.secondary.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .help("输入缩放比例，例如 150")
        .accessibilityIdentifier("zoom-controls")
    }

    private func commitZoomInput() {
        let input = zoomInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")

        guard let percentage = Double(input),
              percentage.isFinite,
              percentage > 0 else {
            zoomInput = model.zoomPercentageInput
            model.statusMessage = "请输入大于 0 的缩放比例，例如 150。"
            return
        }

        model.setZoomFactor(CGFloat(percentage / 100))
        zoomInput = model.zoomPercentageInput
    }

    private func toggleSidebar() {
        withPanelTransaction {
            sidebarVisible.toggle()
        }
    }

    private func toggleInspector() {
        withPanelTransaction {
            inspectorVisible.toggle()
        }
    }

    private func showInspector() {
        withPanelTransaction {
            inspectorVisible = true
        }
    }

    private func withPanelTransaction(_ action: () -> Void) {
        var transaction = Transaction()
        // A panel toggle resizes the AppKit canvas. Disabling implicit
        // animation keeps the canvas from repeatedly invalidating its
        // interactive geometry while the workbench changes width.
        transaction.animation = nil
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction, action)
    }

    private func handleKeyAction(_ action: CanvasKeyAction) {
        switch action {
        case .previous:
            model.previousImage()
        case .next:
            model.nextImage()
        case .toggleDisplayMode:
            if model.canvasMode == .fit {
                model.actualSize()
            } else {
                model.fitImage()
            }
        case .zoomIn:
            model.zoomIn()
        case .zoomOut:
            model.zoomOut()
        case .fit:
            model.fitImage()
        case .infinite:
            model.infiniteCanvas()
        case .actualSize:
            model.actualSize()
        case .rotate:
            model.rotateRight()
        case .inspector:
            toggleInspector()
        case .fullscreen:
            model.toggleFullScreen()
        case .trash:
            model.moveCurrentToTrash()
        }
    }
}

private struct MotionPhotoBadge: View {
    var body: some View {
        Label("动态照片 · 单击播放", systemImage: "livephoto")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.black.opacity(0.62), in: Capsule())
            .shadow(color: .black.opacity(0.24), radius: 6, y: 2)
            .accessibilityLabel("动态照片，单击图片播放")
    }
}

private struct CollapsedPanelRail: View {
    let edge: HorizontalEdge
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.clear
                Image(systemName: edge == .leading ? "chevron.right" : "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 44)
        .frame(maxHeight: .infinity)
        // Keep the collapsed rail opaque so AppKit does not continuously
        // recomposite a live blur while the canvas is being relaid out.
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: edge == .leading ? .trailing : .leading) {
            Divider()
        }
        .contentShape(Rectangle())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityHint("点击展开工作台面板")
        .accessibilityIdentifier(edge == .leading ? "sidebar-expand" : "inspector-expand")
    }
}

private struct PanelCollapseHandle: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Capsule()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 28, height: 58)
                    .overlay {
                        Capsule()
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 7, y: 2)

                Image(systemName: systemImage)
            }
            .frame(width: 52, height: 84)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityHint("点击收起工作台面板")
        .accessibilityIdentifier(title == "收起浏览侧栏" ? "sidebar-collapse" : "inspector-collapse")
    }
}

private struct EmptyViewerState: View {
    let isLoading: Bool
    let hasAsset: Bool
    let openAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("正在加载图片…")
                    .foregroundStyle(.secondary)
            } else if hasAsset {
                Image(systemName: "photo")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.secondary)
                Text("无法显示此图片")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                Text("打开图片开始")
                    .font(.headline)
                Button("打开图片…", action: openAction)
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

private struct StatusBanner: View {
    static let autoDismissNanoseconds: UInt64 = 15_000_000_000

    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .lineLimit(2)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.96),
            in: Capsule()
        )
        .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
    }
}
