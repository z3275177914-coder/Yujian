import ImageViewerCore
import SwiftUI

struct ExportPanelView: View {
    @EnvironmentObject private var model: ImageViewerModel
    @Environment(\.dismiss) private var dismiss

    let isBatch: Bool
    @State private var format: ImageExportFormat = .jpeg
    @State private var resizeEnabled = false
    @State private var width = ""
    @State private var height = ""
    @State private var keepAspectRatio = true
    @State private var quality = 0.9
    @State private var metadataPolicy: ImageMetadataPolicy = .preserve

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("导出格式") {
                    Picker("格式", selection: $format) {
                        ForEach(ImageExportFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }

                    if format == .jpeg || format == .heic {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("质量")
                                Spacer()
                                Text("\(Int(quality * 100))%")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $quality, in: 0.1...1)
                        }
                    }
                }

                Section("调整大小") {
                    Toggle("导出时调整大小", isOn: $resizeEnabled)
                    if resizeEnabled {
                        HStack {
                            TextField("宽度", text: $width)
                                .textFieldStyle(.roundedBorder)
                            Text("×")
                                .foregroundStyle(.secondary)
                            TextField("高度", text: $height)
                                .textFieldStyle(.roundedBorder)
                        }
                        .disabled(!resizeEnabled)

                        Toggle("保持宽高比", isOn: $keepAspectRatio)
                    }
                }

                Section("元数据与隐私") {
                    Picker("导出策略", selection: $metadataPolicy) {
                        ForEach(ImageMetadataPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    Text(metadataPolicy == .preserve
                        ? "保留 ICC、EXIF、IPTC 等可写入元数据。"
                        : "仅移除 GPS 位置，其他可写入元数据保留。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let asset = model.currentAsset {
                    Section("当前图片") {
                        LabeledContent("文件名", value: asset.filename)
                        LabeledContent("原始尺寸", value: asset.dimensionsLabel)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isBatch ? "开始批量转换" : "导出") {
                    performExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBatch ? model.assets.isEmpty : model.currentAsset == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 500)
        .navigationTitle(isBatch ? "批量转换" : "导出图片")
        .onAppear {
            if let asset = model.currentAsset, width.isEmpty, height.isEmpty {
                width = asset.pixelWidth > 0 ? String(asset.pixelWidth) : ""
                height = asset.pixelHeight > 0 ? String(asset.pixelHeight) : ""
            }
        }
    }

    private func performExport() {
        let options = ImageExportOptions(
            width: resizeEnabled ? Int(width) : nil,
            height: resizeEnabled ? Int(height) : nil,
            keepAspectRatio: keepAspectRatio,
            quality: quality,
            metadataPolicy: metadataPolicy
        )
        if isBatch {
            model.batchConvert(format: format, options: options)
        } else {
            model.exportCurrent(format: format, options: options)
        }
        dismiss()
    }
}

struct BatchRenamePanelView: View {
    @EnvironmentObject private var model: ImageViewerModel
    @Environment(\.dismiss) private var dismiss

    @State private var prefix = "图片"
    @State private var startNumber = "1"
    @State private var minimumDigits = "3"

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("命名规则") {
                    TextField("前缀", text: $prefix)
                    TextField("起始编号", text: $startNumber)
                        .onChange(of: startNumber) { _, newValue in
                            startNumber = newValue.filter(\.isNumber)
                        }
                    TextField("最少位数", text: $minimumDigits)
                        .onChange(of: minimumDigits) { _, newValue in
                            minimumDigits = newValue.filter(\.isNumber)
                        }
                }

                Section("预览") {
                    let sampleNumber = Int(startNumber) ?? 1
                    let sampleDigits = max(1, Int(minimumDigits) ?? 3)
                    Text("\(prefix.isEmpty ? "图片" : prefix)-\(String(format: "%0\(sampleDigits)d", sampleNumber)).jpg")
                        .font(.system(.body, design: .monospaced))
                    Text("将按当前文件夹中的文件名顺序重命名 \(model.assets.count) 张图片。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("开始重命名") {
                    let options = BatchRenameOptions(
                        prefix: prefix,
                        startNumber: Int(startNumber) ?? 1,
                        minimumDigits: Int(minimumDigits) ?? 3
                    )
                    model.batchRename(options: options)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.assets.count < 2 || prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460, height: 330)
        .navigationTitle("批量重命名")
    }
}
