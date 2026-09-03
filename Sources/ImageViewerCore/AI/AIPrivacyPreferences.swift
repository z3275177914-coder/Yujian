import Foundation

public enum AIHistoryRetention: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case forever
    case sevenDays
    case thirtyDays
    case ninetyDays

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .forever:
            return "永久保留"
        case .sevenDays:
            return "7 天"
        case .thirtyDays:
            return "30 天"
        case .ninetyDays:
            return "90 天"
        }
    }

    public var maximumAge: TimeInterval? {
        switch self {
        case .forever:
            return nil
        case .sevenDays:
            return 7 * 24 * 60 * 60
        case .thirtyDays:
            return 30 * 24 * 60 * 60
        case .ninetyDays:
            return 90 * 24 * 60 * 60
        }
    }

    public func includes(_ date: Date, now: Date = Date()) -> Bool {
        guard let maximumAge else {
            return true
        }
        return date >= now.addingTimeInterval(-maximumAge)
    }
}

public struct AIPrivacyPreferences: Codable, Equatable, Sendable {
    public var cloudAIConsentGranted: Bool
    public var historyRetention: AIHistoryRetention
    public var clearClipboardAfterHandoff: Bool

    public init(
        cloudAIConsentGranted: Bool = false,
        historyRetention: AIHistoryRetention = .forever,
        clearClipboardAfterHandoff: Bool = false
    ) {
        self.cloudAIConsentGranted = cloudAIConsentGranted
        self.historyRetention = historyRetention
        self.clearClipboardAfterHandoff = clearClipboardAfterHandoff
    }

    private static let key = "ImageViewer.aiPrivacyPreferences"

    public static func load() -> AIPrivacyPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let preferences = try? JSONDecoder().decode(
                  AIPrivacyPreferences.self,
                  from: data
              ) else {
            return AIPrivacyPreferences()
        }
        return preferences
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
