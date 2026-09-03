import Foundation

private enum AIProviderHTTP {
    static func imageBase64(
        imageURL: URL,
        selection: AIImageSelection?
    ) async throws -> String {
        let imageData = try await Task.detached(priority: .userInitiated) {
            try ImageEncodingService.jpegData(
                for: imageURL,
                selection: selection,
                maxPixelSize: 2048
            )
        }.value
        return imageData.base64EncodedString()
    }

    static func makeURL(
        baseURL: String,
        path: String,
        provider: String
    ) throws -> URL {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/\(path)"),
              url.scheme != nil,
              url.host != nil else {
            throw AIProviderError.invalidEndpoint(provider: provider)
        }
        guard AIEndpointPolicy.isAllowed(baseURL) else {
            throw AIProviderError.insecureEndpoint(provider: provider)
        }
        return url
    }

    static func send(
        _ request: URLRequest,
        provider: String
    ) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIProviderError.invalidResponse(provider: provider)
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw AIProviderError.server(
                    provider: provider,
                    statusCode: httpResponse.statusCode,
                    message: serverMessage(from: data, fallback: "请求失败。")
                )
            }
            return data
        } catch let error as AIProviderError {
            throw error
        } catch {
            throw AIProviderError.network(
                provider: provider,
                message: error.localizedDescription
            )
        }
    }

    static func serverMessage(from data: Data, fallback: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let response = object as? [String: Any] else {
            return fallback
        }
        if let error = response["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let message = response["message"] as? String {
            return message
        }
        return fallback
    }
}

public enum AIConnectionTester {
    public static func test(
        configuration: AIProviderConfiguration,
        apiKey: String?
    ) async throws {
        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw AIProviderError.missingAPIKey(provider: configuration.provider.displayName)
        }

        let path: String
        if configuration.provider == .gemini {
            let encodedModel = configuration.model.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? configuration.model
            path = "models/\(encodedModel)"
        } else {
            path = "models"
        }

        var url = try AIProviderHTTP.makeURL(
            baseURL: configuration.baseURL,
            path: path,
            provider: configuration.provider.displayName
        )

        if configuration.provider == .gemini {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw AIProviderError.invalidEndpoint(provider: configuration.provider.displayName)
            }
            components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            guard let queryURL = components.url else {
                throw AIProviderError.invalidEndpoint(provider: configuration.provider.displayName)
            }
            url = queryURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        switch configuration.provider {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            break
        default:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        _ = try await AIProviderHTTP.send(
            request,
            provider: configuration.provider.displayName
        )
    }
}

public struct AnthropicAPIProvider: AIAnalysisProvider, Sendable {
    public let name = "Anthropic Claude"

    private let model: String
    private let baseURL: String
    private let temporaryAPIKey: String?

    public init(
        model: String = AIProviderKind.anthropic.defaultModel,
        baseURL: String = AIProviderKind.anthropic.defaultBaseURL,
        apiKey: String? = nil
    ) {
        let configuration = AIProviderConfiguration(
            provider: .anthropic,
            model: model,
            baseURL: baseURL
        )
        self.model = configuration.model
        self.baseURL = configuration.baseURL
        self.temporaryAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func makeRequest(imageURL: URL, prompt: String) -> AIRequest {
        AIRequest(imageURL: imageURL, prompt: prompt)
    }

    public func ask(
        imageURL: URL,
        prompt: String,
        selection: AIImageSelection? = nil
    ) async throws -> String {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await requestText(
            imageURL: imageURL,
            selection: selection,
            prompt: prompt.isEmpty ? "请分析这张图片。" : prompt
        )
    }

    public func describe(
        imageURL: URL,
        selection: AIImageSelection? = nil
    ) async throws -> String {
        try await requestText(
            imageURL: imageURL,
            selection: selection,
            prompt: "请用中文详细描述这张图片的主体、场景、构图、色彩、风格和可能的上下文。不要臆测无法从图片确认的事实。"
        )
    }

    public func generateCaption(
        imageURL: URL,
        selection: AIImageSelection? = nil
    ) async throws -> String {
        try await requestText(
            imageURL: imageURL,
            selection: selection,
            prompt: "请为这张图片生成 3 条简洁、自然的中文说明或标题，每条不超过 30 个字。"
        )
    }

    public func edit(
        imageURL: URL,
        prompt: String,
        selection: AIImageSelection? = nil
    ) async throws -> Data {
        throw AIProviderError.unsupportedAction(
            provider: name,
            action: AIAction.edit.rawValue
        )
    }

    private func requestText(
        imageURL: URL,
        selection: AIImageSelection?,
        prompt: String
    ) async throws -> String {
        let imageBase64 = try await AIProviderHTTP.imageBase64(
            imageURL: imageURL,
            selection: selection
        )
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1200,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": imageBase64
                        ]
                    ],
                    [
                        "type": "text",
                        "text": prompt
                    ]
                ]
            ]]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = try makeAPIRequest(path: "messages")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData

        let data = try await AIProviderHTTP.send(request, provider: name)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let response = object as? [String: Any],
              let content = response["content"] as? [[String: Any]] else {
            throw AIProviderError.invalidResponse(provider: name)
        }
        let texts = content.compactMap { part -> String? in
            guard part["type"] as? String == "text" else {
                return nil
            }
            return part["text"] as? String
        }.filter { !$0.isEmpty }
        guard !texts.isEmpty else {
            throw AIProviderError.invalidResponse(provider: name)
        }
        return texts.joined(separator: "\n")
    }

    private func makeAPIRequest(path: String) throws -> URLRequest {
        guard let apiKey = apiKey else {
            throw AIProviderError.missingAPIKey(provider: name)
        }
        let url = try AIProviderHTTP.makeURL(
            baseURL: baseURL,
            path: path,
            provider: name
        )
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 120
        return request
    }

    private var apiKey: String? {
        if let temporaryAPIKey, !temporaryAPIKey.isEmpty {
            return temporaryAPIKey
        }
        return KeychainStore.loadAPIKey(for: .anthropic)
    }
}

public struct GeminiAPIProvider: AIAnalysisProvider, Sendable {
    public let name = "Google Gemini"

    private let model: String
    private let baseURL: String
    private let temporaryAPIKey: String?

    public init(
        model: String = AIProviderKind.gemini.defaultModel,
        baseURL: String = AIProviderKind.gemini.defaultBaseURL,
        apiKey: String? = nil
    ) {
        let configuration = AIProviderConfiguration(
            provider: .gemini,
            model: model,
            baseURL: baseURL
        )
        self.model = configuration.model
        self.baseURL = configuration.baseURL
        self.temporaryAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func makeRequest(imageURL: URL, prompt: String) -> AIRequest {
        AIRequest(imageURL: imageURL, prompt: prompt)
    }

    public func ask(
        imageURL: URL,
        prompt: String,
        selection: AIImageSelection? = nil
    ) async throws -> String {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await requestText(
            imageURL: imageURL,
            selection: selection,
            prompt: prompt.isEmpty ? "请分析这张图片。" : prompt
        )
    }

    public func describe(
        imageURL: URL,
        selection: AIImageSelection? = nil
    ) async throws -> String {
        try await requestText(
            imageURL: imageURL,
            selection: selection,
            prompt: "请用中文详细描述这张图片的主体、场景、构图、色彩、风格和可能的上下文。不要臆测无法从图片确认的事实。"
        )
    }

    public func generateCaption(
        imageURL: URL,
        selection: AIImageSelection? = nil
    ) async throws -> String {
        try await requestText(
            imageURL: imageURL,
            selection: selection,
            prompt: "请为这张图片生成 3 条简洁、自然的中文说明或标题，每条不超过 30 个字。"
        )
    }

    public func edit(
        imageURL: URL,
        prompt: String,
        selection: AIImageSelection? = nil
    ) async throws -> Data {
        throw AIProviderError.unsupportedAction(
            provider: name,
            action: AIAction.edit.rawValue
        )
    }

    private func requestText(
        imageURL: URL,
        selection: AIImageSelection?,
        prompt: String
    ) async throws -> String {
        let imageBase64 = try await AIProviderHTTP.imageBase64(
            imageURL: imageURL,
            selection: selection
        )
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["text": prompt],
                    [
                        "inline_data": [
                            "mime_type": "image/jpeg",
                            "data": imageBase64
                        ]
                    ]
                ]
            ]],
            "generationConfig": [
                "maxOutputTokens": 1200
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = try makeAPIRequest()
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let data = try await AIProviderHTTP.send(request, provider: name)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let response = object as? [String: Any],
              let candidates = response["candidates"] as? [[String: Any]] else {
            throw AIProviderError.invalidResponse(provider: name)
        }
        var texts: [String] = []
        for candidate in candidates {
            guard let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                continue
            }
            texts.append(contentsOf: parts.compactMap { $0["text"] as? String })
        }
        let result = texts.filter { !$0.isEmpty }.joined(separator: "\n")
        guard !result.isEmpty else {
            throw AIProviderError.invalidResponse(provider: name)
        }
        return result
    }

    private func makeAPIRequest() throws -> URLRequest {
        guard let apiKey else {
            throw AIProviderError.missingAPIKey(provider: name)
        }
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? model
        guard var components = URLComponents(
            string: "\(base)/models/\(encodedModel):generateContent"
        ) else {
            throw AIProviderError.invalidEndpoint(provider: name)
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw AIProviderError.invalidEndpoint(provider: name)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        return request
    }

    private var apiKey: String? {
        if let temporaryAPIKey, !temporaryAPIKey.isEmpty {
            return temporaryAPIKey
        }
        return KeychainStore.loadAPIKey(for: .gemini)
    }
}

public struct OpenAICompatibleAPIProvider: AIAnalysisProvider, Sendable {
    private let providerKind: AIProviderKind
    private let model: String
    private let baseURL: String
    private let temporaryAPIKey: String?

    public var name: String {
        providerKind == .openAICompatible ? "OpenAI 兼容接口" : providerKind.displayName
    }

    public init(
        model: String? = nil,
        baseURL: String? = nil,
        apiKey: String? = nil,
        provider: AIProviderKind = .openAICompatible
    ) {
        let configuration = AIProviderConfiguration(
            provider: provider,
            model: model,
            baseURL: baseURL
        )
        self.providerKind = provider
        self.model = configuration.model
        self.baseURL = configuration.baseURL
        self.temporaryAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func makeRequest(imageURL: URL, prompt: String) -> AIRequest {
        AIRequest(imageURL: imageURL, prompt: prompt)
    }

    public func ask(
        imageURL: URL,
        prompt: String,
        selection: AIImageSelection? = nil
    ) async throws -> String {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await requestText(
            imageURL: imageURL,
            selection: selection,
            prompt: prompt.isEmpty ? "请分析这张图片。" : prompt
        )
    }

    public func describe(
        imageURL: URL,
        selection: AIImageSelection? = nil
    ) async throws -> String {
        try await requestText(
            imageURL: imageURL,
            selection: selection,
            prompt: "请用中文详细描述这张图片的主体、场景、构图、色彩、风格和可能的上下文。不要臆测无法从图片确认的事实。"
        )
    }

    public func generateCaption(
        imageURL: URL,
        selection: AIImageSelection? = nil
    ) async throws -> String {
        try await requestText(
            imageURL: imageURL,
            selection: selection,
            prompt: "请为这张图片生成 3 条简洁、自然的中文说明或标题，每条不超过 30 个字。"
        )
    }

    public func edit(
        imageURL: URL,
        prompt: String,
        selection: AIImageSelection? = nil
    ) async throws -> Data {
        throw AIProviderError.unsupportedAction(
            provider: name,
            action: AIAction.edit.rawValue
        )
    }

    private func requestText(
        imageURL: URL,
        selection: AIImageSelection?,
        prompt: String
    ) async throws -> String {
        let imageBase64 = try await AIProviderHTTP.imageBase64(
            imageURL: imageURL,
            selection: selection
        )
        let body: [String: Any] = [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "text",
                        "text": prompt
                    ],
                    [
                        "type": "image_url",
                        "image_url": [
                            "url": "data:image/jpeg;base64,\(imageBase64)"
                        ]
                    ]
                ]
            ]],
            "max_tokens": 1200
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = try makeAPIRequest()
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let data = try await AIProviderHTTP.send(request, provider: name)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let response = object as? [String: Any],
              let choices = response["choices"] as? [[String: Any]] else {
            throw AIProviderError.invalidResponse(provider: name)
        }
        var texts: [String] = []
        for choice in choices {
            guard let message = choice["message"] as? [String: Any] else {
                continue
            }
            if let text = message["content"] as? String {
                texts.append(text)
            } else if let parts = message["content"] as? [[String: Any]] {
                texts.append(contentsOf: parts.compactMap { $0["text"] as? String })
            }
        }
        let result = texts.filter { !$0.isEmpty }.joined(separator: "\n")
        guard !result.isEmpty else {
            throw AIProviderError.invalidResponse(provider: name)
        }
        return result
    }

    private func makeAPIRequest() throws -> URLRequest {
        guard let apiKey else {
            throw AIProviderError.missingAPIKey(provider: name)
        }
        let url = try AIProviderHTTP.makeURL(
            baseURL: baseURL,
            path: "chat/completions",
            provider: name
        )
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        return request
    }

    private var apiKey: String? {
        if let temporaryAPIKey, !temporaryAPIKey.isEmpty {
            return temporaryAPIKey
        }
        return KeychainStore.loadAPIKey(for: providerKind)
    }
}
