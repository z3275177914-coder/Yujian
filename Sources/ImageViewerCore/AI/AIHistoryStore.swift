import CryptoKit
import Foundation

public struct AIHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let originalPath: String
    public let createdAt: Date
    public let action: String
    public let prompt: String
    public let resultText: String?
    public let imagePath: String?
    public let inputSource: String?
    public let inputByteCount: Int?

    public var imageURL: URL? {
        imagePath.map { URL(fileURLWithPath: $0) }
    }

    public init(
        id: String = UUID().uuidString,
        originalPath: String,
        createdAt: Date = Date(),
        action: String,
        prompt: String,
        resultText: String? = nil,
        imagePath: String? = nil,
        inputSource: AIInputSource? = nil,
        inputByteCount: Int? = nil
    ) {
        self.id = id
        self.originalPath = originalPath
        self.createdAt = createdAt
        self.action = action
        self.prompt = prompt
        self.resultText = resultText
        self.imagePath = imagePath
        self.inputSource = inputSource?.rawValue
        self.inputByteCount = inputByteCount
    }
}

public enum AIHistoryStore {
    public static func load(
        originalURL: URL,
        retention: AIHistoryRetention = .forever
    ) -> [AIHistoryEntry] {
        let directory = historyDirectory(for: originalURL)
        let fileURL = directory.appendingPathComponent("entries.json")
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? decoder.decode([AIHistoryEntry].self, from: data) else {
            return []
        }
        return entries
            .filter { retention.includes($0.createdAt) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public static func saveText(
        originalURL: URL,
        action: AIAction,
        prompt: String,
        text: String,
        inputSource: AIInputSource = .original,
        inputByteCount: Int? = nil
    ) throws -> AIHistoryEntry {
        let entry = AIHistoryEntry(
            originalPath: originalURL.path,
            action: action.rawValue,
            prompt: prompt,
            resultText: text,
            inputSource: inputSource,
            inputByteCount: inputByteCount
        )
        try append(entry, to: originalURL)
        return entry
    }

    @discardableResult
    public static func saveImage(
        originalURL: URL,
        action: AIAction,
        prompt: String,
        imageData: Data,
        inputSource: AIInputSource = .original,
        inputByteCount: Int? = nil
    ) throws -> AIHistoryEntry {
        let directory = historyDirectory(for: originalURL)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let imageURL = directory.appendingPathComponent("\(UUID().uuidString).png")
        try imageData.write(to: imageURL, options: .atomic)

        let entry = AIHistoryEntry(
            originalPath: originalURL.path,
            action: action.rawValue,
            prompt: prompt,
            imagePath: imageURL.path,
            inputSource: inputSource,
            inputByteCount: inputByteCount
        )
        do {
            try append(entry, to: originalURL)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            throw error
        }
        return entry
    }

    public static func delete(_ entry: AIHistoryEntry, originalURL: URL) throws {
        if let imageURL = entry.imageURL {
            try? FileManager.default.removeItem(at: imageURL)
        }
        let remaining = load(originalURL: originalURL).filter { $0.id != entry.id }
        try write(remaining, to: originalURL)
    }

    public static func clearAll() throws {
        let root = historyRootDirectory()
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        try FileManager.default.removeItem(at: root)
    }

    public static func pruneExpired(retention: AIHistoryRetention) throws {
        guard retention != .forever else {
            return
        }

        let root = historyRootDirectory()
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for directory in directories {
            let fileURL = directory.appendingPathComponent("entries.json")
            guard let data = try? Data(contentsOf: fileURL),
                  let entries = try? decoder.decode([AIHistoryEntry].self, from: data) else {
                continue
            }

            let remaining = entries.filter { entry in
                if retention.includes(entry.createdAt) {
                    return true
                }
                if let imageURL = entry.imageURL {
                    try? FileManager.default.removeItem(at: imageURL)
                }
                return false
            }

            if remaining.isEmpty {
                try? FileManager.default.removeItem(at: directory)
            } else {
                let remainingData = try encoder.encode(remaining)
                try remainingData.write(to: fileURL, options: .atomic)
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func append(_ entry: AIHistoryEntry, to originalURL: URL) throws {
        var entries = load(originalURL: originalURL)
        entries.append(entry)
        try write(entries, to: originalURL)
    }

    private static func write(_ entries: [AIHistoryEntry], to originalURL: URL) throws {
        let directory = historyDirectory(for: originalURL)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(entries)
        try data.write(to: directory.appendingPathComponent("entries.json"), options: .atomic)
    }

    private static func historyDirectory(for originalURL: URL) -> URL {
        historyRootDirectory()
            .appendingPathComponent(historyDigest(for: originalURL), isDirectory: true)
    }

    private static func historyRootDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("ImageViewer", isDirectory: true)
            .appendingPathComponent("AIHistory", isDirectory: true)
    }

    private static func historyDigest(for originalURL: URL) -> String {
        SHA256.hash(data: Data(originalURL.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
