import Foundation
import Security

public enum KeychainStore {
    public static let openAIService = "\(ImageViewerAppIdentity.bundleIdentifier).openai"
    public static let legacyOpenAIService = "\(ImageViewerAppIdentity.legacyBundleIdentifier).openai"

    public static func saveOpenAIAPIKey(_ apiKey: String) throws {
        try saveAPIKey(apiKey, for: .openAI)
    }

    public static func saveAPIKey(_ apiKey: String, for provider: AIProviderKind) throws {
        let data = Data(apiKey.utf8)
        try saveAPIKey(data: data, service: service(for: provider))
    }

    /// Copies legacy credentials into the stable application namespace while
    /// leaving the old item intact for rollback and side-by-side installs.
    public static func migrateLegacyAPIKeys() {
        for provider in AIProviderKind.allCases {
            guard loadAPIKey(service: service(for: provider)) == nil,
                  let legacyValue = loadAPIKey(service: legacyService(for: provider)) else {
                continue
            }
            try? saveAPIKey(
                data: Data(legacyValue.utf8),
                service: service(for: provider)
            )
        }
    }

    private static func saveAPIKey(data: Data, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default"
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.status(updateStatus)
            }
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.status(addStatus)
            }
        default:
            throw KeychainError.status(status)
        }
    }

    public static func loadOpenAIAPIKey() -> String? {
        loadAPIKey(for: .openAI)
    }

    public static func loadAPIKey(for provider: AIProviderKind) -> String? {
        if let value = loadAPIKey(service: service(for: provider)) {
            return value
        }

        guard let legacyValue = loadAPIKey(service: legacyService(for: provider)) else {
            return nil
        }

        // Keep the value usable even if the best-effort copy fails.
        try? saveAPIKey(
            data: Data(legacyValue.utf8),
            service: service(for: provider)
        )
        return legacyValue
    }

    private static func loadAPIKey(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    public static func hasOpenAIAPIKey() -> Bool {
        hasAPIKey(for: .openAI)
    }

    public static func hasAPIKey(for provider: AIProviderKind) -> Bool {
        loadAPIKey(for: provider) != nil
    }

    public static func deleteOpenAIAPIKey() throws {
        try deleteAPIKey(for: .openAI)
    }

    public static func deleteAPIKey(for provider: AIProviderKind) throws {
        try deleteAPIKey(service: service(for: provider))
        try deleteAPIKey(service: legacyService(for: provider))
    }

    private static func deleteAPIKey(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default"
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private static func service(for provider: AIProviderKind) -> String {
        if provider == .openAI {
            return openAIService
        }
        return "\(ImageViewerAppIdentity.bundleIdentifier).ai.\(provider.rawValue)"
    }

    private static func legacyService(for provider: AIProviderKind) -> String {
        if provider == .openAI {
            return legacyOpenAIService
        }
        return "\(ImageViewerAppIdentity.legacyBundleIdentifier).ai.\(provider.rawValue)"
    }
}

public enum KeychainError: LocalizedError {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .status(status):
            SecCopyErrorMessageString(status, nil) as String? ?? "无法访问 macOS 钥匙串（错误码 \(status)）。"
        }
    }
}
