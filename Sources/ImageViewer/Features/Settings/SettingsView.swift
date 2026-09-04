import ImageViewerCore
import SwiftUI

@MainActor
struct SettingsView: @preconcurrency View {
    @ObservedObject var model: ImageViewerModel
    @State private var apiKey = ""
    @State private var modelName = ""
    @State private var baseURL = ""
    @State private var isShowingClearAIHistoryConfirmation = false

    var body: some View {
        Form {
            Section("可自定义快捷键") {
                ShortcutRow(
                    title: "上一张图片",
                    value: model.shortcuts.previous,
                    action: .previous,
                    model: model
                )
                ShortcutRow(
                    title: "下一张图片",
                    value: model.shortcuts.next,
                    action: .next,
                    model: model
                )
                ShortcutRow(
                    title: "旋转",
                    value: model.shortcuts.rotate,
                    action: .rotate,
                    model: model
                )
                ShortcutRow(
                    title: "检查器",
                    value: model.shortcuts.inspector,
                    action: .inspector,
                    model: model
                )
                ShortcutRow(
                    title: "全屏",
                    value: model.shortcuts.fullscreen,
                    action: .fullscreen,
                    model: model
                )

                Text("每个快捷键使用一个字母键。方向键、空格、0、1、2 和 Delete 保持系统默认行为。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("恢复默认快捷键") {
                    model.resetShortcuts()
                }
            }

            Section("性能") {
                Label("图片使用 ImageIO 后台解码，并按尺寸缓存缩略图、预览图和邻近图片。", systemImage: "speedometer")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("清理图片缓存") {
                    DecodedImageCache.shared.removeAll()
                    ThumbnailService.shared.removeAll()
                    model.statusMessage = "图片缓存已清理。"
                }
            }

            Section("鼠标与缩放") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("鼠标灵敏度", systemImage: "cursorarrow.motionlines")
                        Spacer()
                        Text(model.mouseSensitivityLabel)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: $model.mouseSensitivity,
                        in: MouseSensitivityConfiguration.range,
                        step: 0.05
                    )

                    Text("控制鼠标滚轮缩放速度；触控板原生缩放和拖动画布保持 1:1 手感。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("恢复默认灵敏度") {
                    model.resetMouseSensitivity()
                }
            }

            Section("AI 接口") {
                Picker(
                    "服务商",
                    selection: Binding(
                        get: { model.selectedAIProvider },
                        set: { provider in
                            model.selectAIProvider(provider)
                            modelName = model.aiModel
                            baseURL = model.aiBaseURL
                            apiKey = ""
                        }
                    )
                ) {
                    ForEach(AIProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                SecureField(
                    "输入 \(model.selectedAIProvider.displayName) API Key",
                    text: $apiKey
                )
                TextField("模型", text: $modelName)

                if model.selectedAIProvider.requiresCustomBaseURL {
                    TextField("Base URL", text: $baseURL)
                } else {
                    LabeledContent("接口地址", value: model.aiBaseURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    if model.aiAPIKeyConfigured {
                        Label("API Key 已配置", systemImage: "checkmark.shield")
                            .foregroundStyle(.green)
                    } else {
                        Label("尚未配置 API Key", systemImage: "exclamationmark.shield")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("保存") {
                        model.saveAISettings(
                            provider: model.selectedAIProvider,
                            apiKey: apiKey,
                            model: modelName,
                            baseURL: baseURL
                        )
                        apiKey = ""
                    }
                    Button("测试连接") {
                        model.testAIConnection()
                    }
                    .disabled(!model.aiAPIKeyConfigured || model.isAITestingConnection)
                    Button("删除 Key") {
                        model.removeAIAPIKey()
                    }
                    .disabled(!model.aiAPIKeyConfigured)
                }

                if model.isAITestingConnection {
                    ProgressView("正在测试连接…")
                        .controlSize(.small)
                }

                Text("API Key 只保存到 macOS 钥匙串；Provider、模型和自定义接口地址保存到本机配置。云端 AI 会在发送前显示隐私提示。DeepSeek、Anthropic 和 Gemini 支持图片询问、描述和说明；图片编辑目前使用 OpenAI。自定义接口默认要求 HTTPS，localhost 可使用 HTTP。OCR 使用本机 Vision，无需 API Key。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("隐私") {
                Toggle(
                    "ChatGPT 交接后 30 秒清理剪贴板",
                    isOn: $model.aiPrivacyPreferences.clearClipboardAfterHandoff
                )

                Picker(
                    "AI 历史保留期限",
                    selection: $model.aiPrivacyPreferences.historyRetention
                ) {
                    ForEach(AIHistoryRetention.allCases) { retention in
                        Text(retention.displayName).tag(retention)
                    }
                }

                Button("清空全部 AI 历史", role: .destructive) {
                    isShowingClearAIHistoryConfirmation = true
                }

                if model.aiPrivacyPreferences.cloudAIConsentGranted {
                    Button("撤销云端 AI 同意") {
                        model.revokeCloudAIPrivacyConsent()
                    }
                }

                Text("云端 AI 可能会接收图片内容和提示词；AI 历史保存在本机。选择较短的保留期限后，过期记录会在后台清理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("本地工具 / MCP") {
                ForEach(LocalToolPermissionScope.allCases) { scope in
                    Toggle(
                        scope.displayName,
                        isOn: permissionBinding(for: scope)
                    )
                }

                Label(
                    "桥接契约：open_image、get_current_image、get_image_metadata、list_folder_images",
                    systemImage: "link"
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

                Text("只有明确开启对应权限后，应用才会响应 yujian://tool/... 请求；旧 imageviewer://tool/... 仍兼容。当前版本提供本地桥接和权限边界；ChatGPT / MCP 端仍需由外部连接接入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("关于") {
                LabeledContent("版本", value: AppBuildInfo.current.versionLabel)
                LabeledContent("提交", value: AppBuildInfo.current.commitLabel)
                LabeledContent(
                    "构建",
                    value: "\(AppBuildInfo.current.configuration) · \(AppBuildInfo.current.buildDate)"
                )
                if AppBuildInfo.current.branch != "local" {
                    LabeledContent("分支", value: AppBuildInfo.current.branch)
                }
                Text("玉鉴 · 原生 macOS 图片查看器")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 700)
        .padding(.top, 8)
        .onAppear {
            syncAIFields()
        }
        .onChange(of: model.selectedAIProvider) { _, _ in
            syncAIFields()
            apiKey = ""
        }
        .alert("清空 AI 历史？", isPresented: $isShowingClearAIHistoryConfirmation) {
            Button("清空", role: .destructive) {
                model.clearAIHistory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除本机保存的 AI 文字记录和生成图片，且无法恢复。")
        }
    }

    private func syncAIFields() {
        modelName = model.aiModel
        baseURL = model.aiBaseURL
    }

    private func permissionBinding(for scope: LocalToolPermissionScope) -> Binding<Bool> {
        Binding(
            get: { model.localToolPermissions.allows(scope) },
            set: { model.setLocalToolPermission(scope, allowed: $0) }
        )
    }
}

@MainActor
private struct ShortcutRow: @preconcurrency View {
    let title: String
    let value: String
    let action: ShortcutAction
    let model: ImageViewerModel

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(
                "按键",
                text: Binding(
                    get: { value },
                    set: { model.setShortcut(action, value: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .frame(width: 58)
        }
    }
}
