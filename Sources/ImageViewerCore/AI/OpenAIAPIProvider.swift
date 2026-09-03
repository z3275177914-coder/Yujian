import Foundation

public struct OpenAISettings: Codable, Equatable, Sendable {
    public static let defaultModel = "gpt-4.1-mini"

    public var model: String

    public init(model: String = OpenAISettings.defaultModel) {
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultModel
            : model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func load() -> OpenAISettings {
        guard let data = UserDefaults.standard.data(forKey: "ImageViewer.openAISettings"),
              let settings = try? JSONDecoder().decode(OpenAISettings.self, from: data) else {
            return OpenAISettings()
        }
        return OpenAISettings(model: settings.model)
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }
        UserDefaults.standard.set(data, forKey: "ImageViewer.openAISettings")
    }
}

public struct OpenAIAPIProvider: AIAnalysisProvider, Sendable {
    public let name = "OpenAI"

    private let model: String
    private let temporaryAPIKey: String?

    public init(
        model: String = OpenAISettings.load().model,
        apiKey: String? = nil
    ) {
        self.model = OpenAISettings(model: model).model
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
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw OpenAIAPIError.emptyPrompt
        }

        let imageData = try await Task.detached(priority: .userInitiated) {
            try ImageEncodingService.pngData(
                for: imageURL,
                selection: selection,
                maxPixelSize: 2048
            )
        }.value
        let boundary = "ImageViewer-\(UUID().uuidString)"
        var request = try makeRequest(path: "/images/edits")
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeMultipartBody(
            imageData: imageData,
            prompt: prompt,
            boundary: boundary
        )

        let data = try await send(request)
        return try await parseImageData(data)
    }

    private func requestText(
        imageURL: URL,
        selection: AIImageSelection?,
        prompt: String
    ) async throws -> String {
        let imageData = try await Task.detached(priority: .userInitiated) {
            try ImageEncodingService.jpegData(
                for: imageURL,
                selection: selection,
                maxPixelSize: 2048
            )
        }.value
        let imageURLString = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
        let body: [String: Any] = [
            "model": model,
            "input": [[
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": prompt
                    ],
                    [
                        "type": "input_image",
                        "image_url": imageURLString
                    ]
                ]
            ]],
            "max_output_tokens": 1200
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = try makeRequest(path: "/responses")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let responseData = try await send(request)
        return try parseText(responseData)
    }

    private func makeRequest(path: String) throws -> URLRequest {
        guard let apiKey = temporaryAPIKey?.isEmpty == false
            ? temporaryAPIKey
            : KeychainStore.loadOpenAIAPIKey() else {
            throw OpenAIAPIError.missingAPIKey
        }
        guard let url = URL(string: "https://api.openai.com/v1\(path)") else {
            throw OpenAIAPIError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenAIAPIError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw OpenAIAPIError.server(
                    statusCode: httpResponse.statusCode,
                    message: serverMessage(from: data)
                )
            }
            return data
        } catch let error as OpenAIAPIError {
            throw error
        } catch {
            throw OpenAIAPIError.network(error.localizedDescription)
        }
    }

    private func parseText(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let response = object as? [String: Any] else {
            throw OpenAIAPIError.invalidResponse
        }

        if let error = response["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw OpenAIAPIError.server(statusCode: 0, message: message)
        }

        var texts: [String] = []
        if let output = response["output"] as? [[String: Any]] {
            for item in output {
                guard let content = item["content"] as? [[String: Any]] else {
                    continue
                }
                for part in content where part["type"] as? String == "output_text" {
                    if let text = part["text"] as? String, !text.isEmpty {
                        texts.append(text)
                    }
                }
            }
        }

        if texts.isEmpty, let choices = response["choices"] as? [[String: Any]] {
            for choice in choices {
                if let message = choice["message"] as? [String: Any],
                   let text = message["content"] as? String,
                   !text.isEmpty {
                    texts.append(text)
                }
            }
        }

        guard !texts.isEmpty else {
            throw OpenAIAPIError.invalidResponse
        }
        return texts.joined(separator: "\n")
    }

    private func parseImageData(_ data: Data) async throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let response = object as? [String: Any],
              let result = (response["data"] as? [[String: Any]])?.first else {
            throw OpenAIAPIError.invalidResponse
        }

        if let encoded = result["b64_json"] as? String,
           let imageData = Data(base64Encoded: encoded) {
            return imageData
        }
        if let urlString = result["url"] as? String,
           let url = URL(string: urlString) {
            do {
                let (imageData, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw OpenAIAPIError.invalidResponse
                }
                return imageData
            } catch let error as OpenAIAPIError {
                throw error
            } catch {
                throw OpenAIAPIError.network(error.localizedDescription)
            }
        }
        throw OpenAIAPIError.invalidResponse
    }

    private func makeMultipartBody(
        imageData: Data,
        prompt: String,
        boundary: String
    ) -> Data {
        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendUTF8("gpt-image-1\r\n")
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
        body.appendUTF8("\(prompt)\r\n")
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"image[]\"; filename=\"selection.png\"\r\n")
        body.appendUTF8("Content-Type: image/png\r\n\r\n")
        body.append(imageData)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        return body
    }

    private func serverMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let response = object as? [String: Any],
              let error = response["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return "OpenAI API 请求失败。"
        }
        return message
    }
}

public enum OpenAIAPIError: LocalizedError {
    case missingAPIKey
    case emptyPrompt
    case invalidEndpoint
    case invalidResponse
    case server(statusCode: Int, message: String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "尚未配置 OpenAI API Key，请在设置中填写。"
        case .emptyPrompt:
            return "请输入 AI 编辑要求。"
        case .invalidEndpoint:
            return "OpenAI API 地址无效。"
        case .invalidResponse:
            return "OpenAI 返回的数据无法解析。"
        case let .server(statusCode, message) where statusCode > 0:
            return "OpenAI 请求失败（\(statusCode)）：\(message)"
        case let .server(_, message):
            return "OpenAI 请求失败：\(message)"
        case let .network(message):
            return "网络请求失败：\(message)"
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
