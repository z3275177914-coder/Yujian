import Foundation

enum ShortcutAction {
    case previous
    case next
    case rotate
    case inspector
    case fullscreen
}

struct ShortcutConfiguration: Codable, Equatable, Sendable {
    var previous = "a"
    var next = "d"
    var rotate = "r"
    var inspector = "i"
    var fullscreen = "f"

    static let defaults = ShortcutConfiguration()

    static func load() -> ShortcutConfiguration {
        guard let data = UserDefaults.standard.data(forKey: "ImageViewer.shortcutConfiguration"),
              let configuration = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data) else {
            return defaults
        }
        return configuration.sanitized()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(sanitized()) else {
            return
        }
        UserDefaults.standard.set(data, forKey: "ImageViewer.shortcutConfiguration")
    }

    func sanitized() -> ShortcutConfiguration {
        var result = self
        result.previous = Self.normalize(previous, fallback: Self.defaults.previous)
        result.next = Self.normalize(next, fallback: Self.defaults.next)
        result.rotate = Self.normalize(rotate, fallback: Self.defaults.rotate)
        result.inspector = Self.normalize(inspector, fallback: Self.defaults.inspector)
        result.fullscreen = Self.normalize(fullscreen, fallback: Self.defaults.fullscreen)
        return result
    }

    private static func normalize(_ value: String, fallback: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.first.map(String.init) ?? fallback
    }
}
