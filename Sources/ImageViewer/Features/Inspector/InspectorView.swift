import AppKit
import ImageViewerCore
import SwiftUI

@MainActor
struct InspectorView: @preconcurrency View {
    @EnvironmentObject private var model: ImageViewerModel
    @EnvironmentObject private var pixelSampleStore: PixelSampleStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("检查器", selection: $model.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)
            .transaction { transaction in
                transaction.animation = nil
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.inspectorTab {
                    case .info:
                        infoContent
                    case .adjust:
                        adjustContent
                    case .ai:
                        aiContent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        // Avoid a full-height live blur during inspector scrolling and tab
        // switches; the window background is cheaper and remains readable in
        // both appearances.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            InspectorSection(title: "图片信息", systemImage: "info.circle") {
                if let fields = model.metadata?.information {
                    MetadataFieldList(fields: fields)
                } else if model.currentAsset != nil {
                    ProgressView("正在读取元数据…")
                        .controlSize(.small)
                } else {
                    EmptyInspectorState(text: "打开图片以查看信息。")
                }
            }

            Divider()

            InspectorSection(title: "EXIF 信息", systemImage: "camera") {
                if let fields = model.metadata?.exif, !fields.isEmpty {
                    MetadataFieldList(fields: fields)
                } else if model.currentAsset != nil, model.metadata == nil {
                    ProgressView("正在读取元数据…")
                        .controlSize(.small)
                } else {
                    EmptyInspectorState(text: "未找到 EXIF 数据。")
                }
            }

            Divider()

            InspectorSection(title: "高级元数据", systemImage: "list.bullet.rectangle") {
                if let fields = model.metadata?.advanced, !fields.isEmpty {
                    MetadataFieldList(fields: fields)
                } else if model.currentAsset != nil, model.metadata == nil {
                    ProgressView("正在读取元数据…")
                        .controlSize(.small)
                } else {
                    EmptyInspectorState(text: "未找到高级元数据。")
                }
            }

            Divider()

            InspectorSection(title: "检查工具", systemImage: "waveform.path.ecg") {
                VStack(alignment: .leading, spacing: 10) {
                    if let histogram = model.histogram {
                        HistogramView(histogram: histogram)
                        Text("基于当前显示代理图计算，共 \(histogram.totalPixels) 个像素")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if model.isInspectionLoading {
                        ProgressView("正在计算直方图…")
                            .controlSize(.small)
                    } else {
                        Text("打开图片后将在后台计算 RGB / 亮度直方图。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    if let sample = pixelSampleStore.value {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(
                                    red: Double(sample.red) / 255,
                                    green: Double(sample.green) / 255,
                                    blue: Double(sample.blue) / 255
                                ))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sample.hexadecimal)
                                    .font(.caption.monospaced().weight(.semibold))
                                Text(sample.rgbaLabel)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("当前像素")
                        .accessibilityValue("\(sample.hexadecimal)，\(sample.rgbaLabel)")
                    } else {
                        Text("将鼠标移动到画布上的图片区域以采样像素。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var adjustContent: some View {
        InspectorSection(title: "调整", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 10) {
                if model.currentAsset == nil {
                    EmptyInspectorState(text: "打开图片以使用调整功能。")
                } else {
                    HStack {
                        Text("实时预览")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            model.undoEdits()
                        } label: {
                            Label("撤销", systemImage: "arrow.uturn.backward")
                        }
                        .labelStyle(.iconOnly)
                        .help("撤销编辑")
                        .disabled(!model.canUndoEdits)
                        Button {
                            model.redoEdits()
                        } label: {
                            Label("重做", systemImage: "arrow.uturn.forward")
                        }
                        .labelStyle(.iconOnly)
                        .help("重做编辑")
                        .disabled(!model.canRedoEdits)
                        Button("恢复默认") {
                            model.resetAdjustments()
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.hasPreviewEdits)
                    }

                    adjustmentSlider(
                        title: "亮度",
                        systemImage: "sun.max",
                        value: adjustmentBinding(\.brightness),
                        range: -1...1,
                        valueText: signedValue(model.adjustments.brightness)
                    )

                    adjustmentSlider(
                        title: "对比度",
                        systemImage: "circle.lefthalf.filled",
                        value: adjustmentBinding(\.contrast),
                        range: 0...2,
                        valueText: decimalValue(model.adjustments.contrast)
                    )

                    adjustmentSlider(
                        title: "饱和度",
                        systemImage: "paintpalette",
                        value: adjustmentBinding(\.saturation),
                        range: 0...2,
                        valueText: decimalValue(model.adjustments.saturation)
                    )

                    adjustmentSlider(
                        title: "锐度",
                        systemImage: "triangle.lefthalf.filled",
                        value: adjustmentBinding(\.sharpness),
                        range: 0...2,
                        valueText: decimalValue(model.adjustments.sharpness)
                    )

                    adjustmentSlider(
                        title: "曝光",
                        systemImage: "sun.horizon",
                        value: adjustmentBinding(\.exposure),
                        range: -2...2,
                        valueText: signedValue(model.adjustments.exposure)
                    )

                    adjustmentSlider(
                        title: "高光",
                        systemImage: "sun.max.trianglebadge.exclamationmark",
                        value: adjustmentBinding(\.highlights),
                        range: -1...1,
                        valueText: signedValue(model.adjustments.highlights)
                    )

                    adjustmentSlider(
                        title: "阴影",
                        systemImage: "moon",
                        value: adjustmentBinding(\.shadows),
                        range: -1...1,
                        valueText: signedValue(model.adjustments.shadows)
                    )

                    adjustmentSlider(
                        title: "色温",
                        systemImage: "thermometer.medium",
                        value: adjustmentBinding(\.temperature),
                        range: -1...1,
                        valueText: signedValue(model.adjustments.temperature)
                    )

                    adjustmentSlider(
                        title: "色调",
                        systemImage: "paintbrush.pointed",
                        value: adjustmentBinding(\.tint),
                        range: -1...1,
                        valueText: signedValue(model.adjustments.tint)
                    )

                    Divider()

                    Text("变换")
                        .font(.subheadline.weight(.semibold))

                    HStack {
                        Button {
                            model.rotateLeft()
                        } label: {
                            Label("向左旋转", systemImage: "rotate.left")
                        }
                        Button {
                            model.rotateRight()
                        } label: {
                            Label("向右旋转", systemImage: "rotate.right")
                        }
                    }

                    Button {
                        model.toggleFlip()
                    } label: {
                        Label("水平翻转", systemImage: "arrow.left.and.right")
                    }

                    HStack {
                        Button {
                            model.beginCrop()
                        } label: {
                            Label("裁剪", systemImage: "crop")
                        }
                        .disabled(model.isCropSelectionMode)

                        if model.cropSelection != nil {
                            Button("清除裁剪") {
                                model.clearCrop()
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    if model.isCropSelectionMode {
                        Text("请在画布上拖出裁剪区域，松开鼠标后应用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        model.toggleOriginalPreview()
                    } label: {
                        Label(
                            model.isShowingOriginalPreview ? "显示编辑结果" : "查看原图",
                            systemImage: model.isShowingOriginalPreview ? "photo" : "rectangle.on.rectangle"
                        )
                    }
                    .disabled(!model.hasPreviewEdits)

                    Text("调整和变换仅作用于当前预览，原始图片不会被覆盖。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func adjustmentSlider(
        title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 8)
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }

    private func adjustmentBinding(
        _ keyPath: WritableKeyPath<ImageAdjustments, Double>
    ) -> Binding<Double> {
        Binding(
            get: { model.adjustments[keyPath: keyPath] },
            set: { model.setAdjustment(keyPath, value: $0) }
        )
    }

    private func decimalValue(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func signedValue(_ value: Double) -> String {
        String(format: "%+.2f", value)
    }

    private var aiContent: some View {
        InspectorSection(title: "AI 工作区", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                if let asset = model.currentAsset {
                    HStack(spacing: 10) {
                        Image(systemName: "photo")
                            .frame(width: 38, height: 38)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("当前图片")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(asset.filename)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }
                    }
                } else {
                    EmptyInspectorState(text: "打开图片以使用 AI 工作区。")
                }

                Picker(
                    "AI 接口",
                    selection: Binding(
                        get: { model.selectedAIProvider },
                        set: { model.selectAIProvider($0) }
                    )
                ) {
                    ForEach(AIProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("AI 接口")

                Picker("发送来源", selection: $model.aiInputSource) {
                    ForEach(AIInputSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isAIRequesting)
                .accessibilityLabel("AI 输入来源")
                Text("发送前会按 \(model.aiProviderDisplayName) 的限制生成临时图片；原图不会被覆盖。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("提示词")
                    .font(.subheadline.weight(.semibold))

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.aiPrompt)
                        .frame(minHeight: 112)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                    if model.aiPrompt.isEmpty {
                        Text("描述这张图片…")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

                HStack(spacing: 8) {
                    aiActionButton(.ask)
                    aiActionButton(.describe)
                }

                HStack(spacing: 8) {
                    aiActionButton(.ocr)
                    aiActionButton(.caption)
                }

                HStack(spacing: 8) {
                    Button {
                        model.beginAISelection()
                    } label: {
                        Label(
                            model.isAISelectionMode ? "请在画布上拖选" : "选择局部区域",
                            systemImage: "viewfinder"
                        )
                    }
                    .disabled(model.currentAsset == nil || model.isAIRequesting)

                    if model.aiSelection != nil {
                        Button("清除选区") {
                            model.clearAISelection()
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if let selection = model.aiSelection {
                    Text("已选择区域：\(Int(selection.width * 100))% × \(Int(selection.height * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    model.runAI(.edit)
                } label: {
                    Label("AI 编辑并保存新版本", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.currentAsset == nil
                        || model.isAIRequesting
                        || !model.aiProviderSupportsImageEditing
                )

                if !model.aiProviderSupportsImageEditing {
                    Text("当前接口支持图片询问、描述和说明；图片编辑请切换到 OpenAI。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                Button {
                    model.openInChatGPT()
                } label: {
                    Label("打开 ChatGPT 桌面端", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.currentAsset == nil || model.isAIRequesting)

                if model.isAIRequesting {
                    ProgressView("AI 正在处理…")
                        .controlSize(.small)
                }

                if !model.aiResultText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("结果")
                            .font(.subheadline.weight(.semibold))
                        Text(model.aiResultText)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                if !model.aiHistory.isEmpty {
                    DisclosureGroup("AI 历史（\(model.aiHistory.count)）") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.aiHistory.prefix(8)) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(entry.action)
                                            .font(.caption.weight(.semibold))
                                        Spacer()
                                        Text(entry.inputSource.flatMap(AIInputSource.init(rawValue:))?.displayName ?? "原图")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.secondary)
                                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let resultText = entry.resultText {
                                        Text(resultText)
                                            .font(.caption)
                                            .lineLimit(4)
                                            .textSelection(.enabled)
                                    } else if let imageURL = entry.imageURL {
                                        Text("已保存图片版本")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Button("在访达中显示") {
                                            FileOperations.revealInFinder(imageURL)
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.caption)
                                    }
                                    HStack {
                                        Spacer()
                                        Button("删除此记录") {
                                            model.deleteAIHistoryEntry(entry)
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                Text("图片和提示词会复制到剪贴板，然后打开 ChatGPT 桌面端。请按 ⌘V 粘贴后提交。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func aiActionButton(_ action: AIAction) -> some View {
        Button {
            model.runAI(action)
        } label: {
            Text(action.rawValue)
                .frame(maxWidth: .infinity)
        }
        .disabled(model.currentAsset == nil || model.isAIRequesting)
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
    }
}

private struct MetadataFieldList: View {
    let fields: [MetadataField]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(fields) { field in
                MetadataFieldRow(field: field)
                if field.id != fields.last?.id {
                    Divider()
                }
            }
        }
    }
}

private struct MetadataFieldRow: View {
    let field: MetadataField

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(field.value)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 2)

            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(field.value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy \(field.label)")
        }
        .padding(.vertical, 8)
    }
}

private struct HistogramView: View {
    let histogram: ImageHistogram

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.08))
                histogramPath(histogram.luminance, in: proxy.size)
                    .stroke(Color.primary.opacity(0.60), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                histogramPath(histogram.red, in: proxy.size)
                    .stroke(.red.opacity(0.60), lineWidth: 0.8)
                histogramPath(histogram.green, in: proxy.size)
                    .stroke(.green.opacity(0.60), lineWidth: 0.8)
                histogramPath(histogram.blue, in: proxy.size)
                    .stroke(.blue.opacity(0.60), lineWidth: 0.8)
            }
        }
        .frame(height: 116)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("RGB 和亮度直方图")
        .accessibilityValue("共 \(histogram.totalPixels) 个像素")
    }

    private func histogramPath(_ values: [Int], in size: CGSize) -> Path {
        guard values.count > 1, size.width > 0, size.height > 0 else {
            return Path()
        }
        let maximum = CGFloat(max(1, histogram.maximumBinCount))
        var path = Path()
        for (index, value) in values.enumerated() {
            let progress = CGFloat(index) / CGFloat(values.count - 1)
            let point = CGPoint(
                x: progress * size.width,
                y: size.height - min(1, CGFloat(value) / maximum) * size.height
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

private struct EmptyInspectorState: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
