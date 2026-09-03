import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageViewerCore

@Test("AI selection is clamped to image bounds")
func aiSelectionIsClamped() {
    let selection = AIImageSelection(x: -0.2, y: 0.25, width: 1.5, height: 1).clamped

    #expect(selection.x == 0)
    #expect(selection.y == 0.25)
    #expect(selection.width == 1)
    #expect(selection.height == 0.75)
}

@Test("AI image encoding crops a selected region")
func aiImageEncodingCropsSelection() throws {
    let directory = try makeAITemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("source.png")
    try makeAITestPNG(at: sourceURL, width: 20, height: 10)

    let image = try ImageEncodingService.image(
        for: sourceURL,
        selection: AIImageSelection(x: 0.25, y: 0.2, width: 0.5, height: 0.5),
        maxPixelSize: 2048
    )

    #expect(image.width == 10)
    #expect(image.height == 5)
}

@Test("OpenAI settings falls back to a usable model")
func openAISettingsHasDefaultModel() {
    #expect(!OpenAISettings().model.isEmpty)
    #expect(OpenAISettings(model: "  ").model == OpenAISettings.defaultModel)
}

@Test("AI provider configuration supports built-in and custom endpoints")
func aiProviderConfigurationSupportsMultipleProviders() {
    #expect(AIProviderKind.allCases.contains(.openAI))
    #expect(AIProviderKind.allCases.contains(.deepSeek))
    #expect(AIProviderKind.allCases.contains(.anthropic))
    #expect(AIProviderKind.allCases.contains(.gemini))
    #expect(AIProviderKind.allCases.contains(.openAICompatible))

    let custom = AIProviderConfiguration(
        provider: .openAICompatible,
        model: " vision-model ",
        baseURL: " https://example.com/v1/ "
    )
    #expect(custom.model == "vision-model")
    #expect(custom.baseURL == "https://example.com/v1/")

    let defaults = AIProviderConfiguration(
        provider: .anthropic,
        model: " ",
        baseURL: " "
    )
    #expect(defaults.model == AIProviderKind.anthropic.defaultModel)
    #expect(defaults.baseURL == AIProviderKind.anthropic.defaultBaseURL)

    let deepSeek = AIProviderConfiguration(provider: .deepSeek)
    #expect(deepSeek.model == "deepseek-v4-flash-vision-exp")
    #expect(deepSeek.baseURL == "https://api.deepseek.com")
}

@Test("AI provider errors keep the provider context")
func aiProviderErrorIncludesProviderName() {
    let error = AIProviderError.missingAPIKey(provider: "Google Gemini")
    #expect(error.errorDescription == "尚未配置 Google Gemini API Key，请在设置中填写。")
}

@Test("AI endpoint policy protects remote custom endpoints")
func aiEndpointPolicyAllowsHTTPSAndLocalHTTPOnly() {
    #expect(AIEndpointPolicy.isAllowed("https://example.com/v1"))
    #expect(AIEndpointPolicy.isAllowed("http://localhost:11434/v1"))
    #expect(AIEndpointPolicy.isAllowed("http://127.0.0.1:8080"))
    #expect(!AIEndpointPolicy.isAllowed("http://example.com/v1"))
    #expect(!AIEndpointPolicy.isAllowed("file:///tmp/endpoint"))
}

@Test("AI history retention has explicit privacy windows")
func aiHistoryRetentionWindows() {
    let now = Date(timeIntervalSince1970: 1_000_000)

    #expect(AIHistoryRetention.forever.includes(now.addingTimeInterval(-10_000), now: now))
    #expect(AIHistoryRetention.sevenDays.includes(now.addingTimeInterval(-6 * 24 * 60 * 60), now: now))
    #expect(!AIHistoryRetention.sevenDays.includes(now.addingTimeInterval(-8 * 24 * 60 * 60), now: now))
    #expect(AIHistoryRetention.allCases.count == 4)
}

@Test("AI input preparation creates and cleans edited temporary files")
func aiInputPreparationCreatesAndCleansEditedTemporaryFiles() throws {
    let directory = try makeAITemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("source.png")
    try makeAITestPNG(at: sourceURL, width: 80, height: 40)
    let capabilities = AIProviderCapabilities(
        provider: .openAI,
        maxPixelSize: 64,
        maxBytes: 1_024 * 1_024
    )

    let input = try AIInputService.prepare(
        sourceURL: sourceURL,
        source: .edited,
        recipe: EditRecipe(adjustments: ImageAdjustments(brightness: 0.2)),
        selection: nil,
        action: .describe,
        capabilities: capabilities
    )
    #expect(input.isTemporary)
    #expect(input.url != sourceURL)
    #expect(FileManager.default.fileExists(atPath: input.url.path))
    #expect(input.byteCount > 0)

    AIInputService.cleanup(input)
    #expect(!FileManager.default.fileExists(atPath: input.url.path))
}

@Test("AI provider capabilities expose a consistent format and editing matrix")
func aiProviderCapabilitiesExposeMatrix() {
    #expect(AIProviderKind.openAI.capabilities.supportsImageEditing)
    #expect(AIProviderKind.deepSeek.capabilities.supportsVision)
    #expect(!AIProviderKind.deepSeek.capabilities.supportsImageEditing)
    #expect(!AIProviderKind.gemini.capabilities.supportsImageEditing)
    #expect(AIProviderKind.openAI.capabilities.editingFormat == .png)
    #expect(AIProviderKind.anthropic.capabilities.analysisFormat == .jpeg)
    #expect(AIProviderKind.openAI.capabilities.timeout >= 5)
}

@Test("DeepSeek uses the existing OpenAI-compatible image provider")
func deepSeekUsesOpenAICompatibleProvider() {
    let provider = OpenAICompatibleAPIProvider(provider: .deepSeek)
    #expect(provider.name == "DeepSeek")
    #expect(
        provider.makeRequest(imageURL: URL(fileURLWithPath: "/tmp/image.jpg"), prompt: "描述图片").prompt
            == "描述图片"
    )
}

private func makeAITemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImageViewerAITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func makeAITestPNG(at url: URL, width: Int, height: Int) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(destination))
}
