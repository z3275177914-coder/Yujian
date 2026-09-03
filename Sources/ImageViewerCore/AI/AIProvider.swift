import AppKit
import CoreGraphics
import Foundation

public struct AIRequest: Hashable, Sendable {
    public let imageURL: URL
    public let prompt: String

    public init(imageURL: URL, prompt: String) {
        self.imageURL = imageURL
        self.prompt = prompt
    }
}

public enum AIInputSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case original
    case edited
    case selection

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .original: return "原图"
        case .edited: return "编辑结果"
        case .selection: return "当前选区"
        }
    }
}

public struct AIProviderCapabilities: Equatable, Sendable {
    public let provider: AIProviderKind
    public let supportsVision: Bool
    public let supportsImageEditing: Bool
    public let maxPixelSize: Int
    public let maxBytes: Int
    public let analysisFormat: ImageExportFormat
    public let editingFormat: ImageExportFormat
    public let timeout: TimeInterval

    public init(
        provider: AIProviderKind,
        supportsVision: Bool = true,
        supportsImageEditing: Bool = false,
        maxPixelSize: Int = 2_048,
        maxBytes: Int = 8 * 1_024 * 1_024,
        analysisFormat: ImageExportFormat = .jpeg,
        editingFormat: ImageExportFormat = .png,
        timeout: TimeInterval = 120
    ) {
        self.provider = provider
        self.supportsVision = supportsVision
        self.supportsImageEditing = supportsImageEditing
        self.maxPixelSize = max(256, maxPixelSize)
        self.maxBytes = max(256 * 1_024, maxBytes)
        self.analysisFormat = analysisFormat
        self.editingFormat = editingFormat
        self.timeout = max(5, timeout)
    }
}

public enum AIAction: String, CaseIterable, Identifiable, Sendable {
    case ask = "询问 AI"
    case describe = "图片描述"
    case ocr = "识别文字"
    case caption = "生成说明"
    case edit = "AI 编辑"

    public var id: String { rawValue }
}

public enum AIProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI = "openai"
    case deepSeek = "deepseek"
    case anthropic = "anthropic"
    case gemini = "gemini"
    case openAICompatible = "openai-compatible"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .deepSeek:
            return "DeepSeek"
        case .anthropic:
            return "Anthropic Claude"
        case .gemini:
            return "Google Gemini"
        case .openAICompatible:
            return "自定义 OpenAI 兼容接口"
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAI:
            return "gpt-4.1-mini"
        case .deepSeek:
            return "deepseek-v4-flash-vision-exp"
        case .anthropic:
            return "claude-3-5-haiku-latest"
        case .gemini:
            return "gemini-2.0-flash"
        case .openAICompatible:
            return "gpt-4o-mini"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAI:
            return "https://api.openai.com/v1"
        case .deepSeek:
            return "https://api.deepseek.com"
        case .anthropic:
            return "https://api.anthropic.com/v1"
        case .gemini:
            return "https://generativelanguage.googleapis.com/v1beta"
        case .openAICompatible:
            return "https://api.openai.com/v1"
        }
    }

    public var supportsImageEditing: Bool {
        capabilities.supportsImageEditing
    }

    public var capabilities: AIProviderCapabilities {
        switch self {
        case .openAI:
            return AIProviderCapabilities(provider: self, supportsImageEditing: true)
        case .deepSeek, .anthropic, .gemini, .openAICompatible:
            return AIProviderCapabilities(provider: self)
        }
    }

    public var requiresCustomBaseURL: Bool {
        self == .openAICompatible
    }

    public static let selectedProviderKey = "ImageViewer.selectedAIProvider"

    public static func loadSelected() -> AIProviderKind {
        guard let rawValue = UserDefaults.standard.string(forKey: selectedProviderKey),
              let provider = AIProviderKind(rawValue: rawValue) else {
            return .openAI
        }
        return provider
    }

    public func saveAsSelected() {
        UserDefaults.standard.set(rawValue, forKey: Self.selectedProviderKey)
    }
}

public struct AIProviderConfiguration: Codable, Equatable, Sendable {
    public let provider: AIProviderKind
    public var model: String
    public var baseURL: String

    public init(
        provider: AIProviderKind,
        model: String? = nil,
        baseURL: String? = nil
    ) {
        self.provider = provider
        let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.model = normalizedModel.isEmpty ? provider.defaultModel : normalizedModel

        let normalizedBaseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.baseURL = normalizedBaseURL.isEmpty ? provider.defaultBaseURL : normalizedBaseURL
    }

    public static func load(for provider: AIProviderKind) -> AIProviderConfiguration {
        let key = "ImageViewer.aiProviderConfiguration.\(provider.rawValue)"
        if let data = UserDefaults.standard.data(forKey: key),
           let configuration = try? JSONDecoder().decode(
               AIProviderConfiguration.self,
               from: data
           ) {
            return AIProviderConfiguration(
                provider: provider,
                model: configuration.model,
                baseURL: configuration.baseURL
            )
        }

        if provider == .openAI {
            return AIProviderConfiguration(
                provider: provider,
                model: OpenAISettings.load().model
            )
        }
        return AIProviderConfiguration(provider: provider)
    }

    public func save() {
        let key = "ImageViewer.aiProviderConfiguration.\(provider.rawValue)"
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}

public enum AIProviderError: LocalizedError, Sendable {
    case missingAPIKey(provider: String)
    case emptyPrompt
    case invalidEndpoint(provider: String)
    case insecureEndpoint(provider: String)
    case invalidResponse(provider: String)
    case unsupportedAction(provider: String, action: String)
    case server(provider: String, statusCode: Int, message: String)
    case network(provider: String, message: String)

    public var errorDescription: String? {
        switch self {
        case let .missingAPIKey(provider):
            return "尚未配置 \(provider) API Key，请在设置中填写。"
        case .emptyPrompt:
            return "请输入 AI 编辑要求。"
        case let .invalidEndpoint(provider):
            return "\(provider) API 地址无效。"
        case let .insecureEndpoint(provider):
            return "\(provider) API 地址必须使用 HTTPS；仅允许 localhost 本地接口使用 HTTP。"
        case let .invalidResponse(provider):
            return "\(provider) 返回的数据无法解析。"
        case let .unsupportedAction(provider, action):
            return "\(provider) 暂不支持“\(action)”功能。"
        case let .server(provider, statusCode, message) where statusCode > 0:
            return "\(provider) 请求失败（\(statusCode)）：\(message)"
        case let .server(provider, _, message):
            return "\(provider) 请求失败：\(message)"
        case let .network(provider, message):
            return "\(provider) 网络请求失败：\(message)"
        }
    }
}

public enum AIEndpointPolicy {
    public static func isAllowed(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return false
        }

        if scheme == "https" {
            return true
        }

        guard scheme == "http" else {
            return false
        }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }
}

public struct AIImageSelection: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(rect: CGRect) {
        self.init(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    public var clamped: AIImageSelection {
        let x = min(1, max(0, self.x))
        let y = min(1, max(0, self.y))
        let maxWidth = max(0, 1 - x)
        let maxHeight = max(0, 1 - y)
        return AIImageSelection(
            x: x,
            y: y,
            width: min(max(0, width), maxWidth),
            height: min(max(0, height), maxHeight)
        )
    }
}

public protocol AIProvider: Sendable {
    var name: String { get }
    func makeRequest(imageURL: URL, prompt: String) -> AIRequest
}

public protocol AIAnalysisProvider: AIProvider {
    func ask(imageURL: URL, prompt: String, selection: AIImageSelection?) async throws -> String
    func describe(imageURL: URL, selection: AIImageSelection?) async throws -> String
    func generateCaption(imageURL: URL, selection: AIImageSelection?) async throws -> String
    func edit(imageURL: URL, prompt: String, selection: AIImageSelection?) async throws -> Data
}

public struct ChatGPTExternalProvider: AIProvider, Sendable {
    public let name = "ChatGPT"

    public init() {}

    public func makeRequest(imageURL: URL, prompt: String) -> AIRequest {
        AIRequest(imageURL: imageURL, prompt: prompt)
    }
}

@MainActor
public enum AIHandoffService {
    public static func openInChatGPT(
        request: AIRequest,
        clearPasteboardAfter delay: TimeInterval? = nil
    ) -> String {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "请分析这张图片。"
            : request.prompt

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setString(prompt, forType: .string)
        item.setString(request.imageURL.path, forType: .fileURL)

        if let image = NSImage(contentsOf: request.imageURL),
           let tiffData = image.tiffRepresentation {
            item.setData(tiffData, forType: .tiff)
        }

        _ = pasteboard.writeObjects([item])
        let handoffChangeCount = pasteboard.changeCount

        if let delay, delay > 0 {
            Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      pasteboard.changeCount == handoffChangeCount else {
                    return
                }
                pasteboard.clearContents()
            }
        }

        let desktopBundleIdentifiers = [
            "com.openai.codex",
            "com.openai.chatgpt"
        ]

        if let applicationURL = desktopBundleIdentifiers
            .compactMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:))
            .first {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            return "已打开 ChatGPT 桌面端。图片和提示词已复制，请在聊天框按 ⌘V 后提交。"
        }

        if let chatGPTURL = URL(string: "https://chatgpt.com/") {
            NSWorkspace.shared.open(chatGPTURL)
        }

        return "未找到 ChatGPT 桌面端，已打开网页版。图片和提示词已复制，请在输入框中粘贴并提交。"
    }
}
