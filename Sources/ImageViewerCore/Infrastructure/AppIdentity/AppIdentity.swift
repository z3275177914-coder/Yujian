import Foundation

/// Stable public identity for the 玉鉴 application.
///
/// The legacy values remain here deliberately: changing an application
/// identity is a data migration, not just a metadata edit. Keep these values
/// stable after the first public release.
public enum ImageViewerAppIdentity {
    public static let bundleIdentifier = "io.github.z3275177914-coder.yujian"
    public static let legacyBundleIdentifier = "com.imageviewer.mac"

    public static let urlScheme = "yujian"
    public static let legacyURLScheme = "imageviewer"

    public static let supportedURLSchemes: Set<String> = [
        urlScheme,
        legacyURLScheme
    ]

    public static func acceptsURLScheme(_ scheme: String?) -> Bool {
        guard let scheme else {
            return false
        }
        return supportedURLSchemes.contains(scheme.lowercased())
    }
}

/// Performs the one-time migration needed when the public application
/// identity changes from the pre-release bundle ID to the stable one.
public enum AppIdentityMigration {
    private static let defaultsMigrationMarkerKey =
        "ImageViewer.appIdentityMigration.bundleIdentifier.v1"

    /// Runs all identity migrations. Every operation is intentionally
    /// best-effort: a cache must never prevent the still-image viewer from
    /// launching, and a legacy Keychain value remains readable if copying it
    /// to the new service is temporarily unavailable.
    public static func run() {
        migrateUserDefaults(
            in: .standard,
            legacyDomainName: ImageViewerAppIdentity.legacyBundleIdentifier,
            currentDomainName: ImageViewerAppIdentity.bundleIdentifier
        )
        migrateMotionPhotoCache()
        KeychainStore.migrateLegacyAPIKeys()
    }

    /// Migrates the old application defaults domain without overwriting values
    /// already written by the new application identity.
    static func migrateUserDefaults(
        in defaults: UserDefaults,
        legacyDomainName: String,
        currentDomainName: String
    ) {
        let currentDomain = defaults.persistentDomain(forName: currentDomainName) ?? [:]
        if currentDomain[defaultsMigrationMarkerKey] as? Bool == true {
            return
        }

        let legacyDomain = defaults.persistentDomain(forName: legacyDomainName) ?? [:]
        var mergedDomain = mergedPersistentDomain(
            legacy: legacyDomain,
            current: currentDomain
        )
        mergedDomain[defaultsMigrationMarkerKey] = true
        defaults.setPersistentDomain(mergedDomain, forName: currentDomainName)
    }

    /// Exposed internally for deterministic migration tests.
    static func mergedPersistentDomain(
        legacy: [String: Any],
        current: [String: Any]
    ) -> [String: Any] {
        var merged = legacy
        current.forEach { key, value in
            merged[key] = value
        }
        return merged
    }

    static func migrateMotionPhotoCache(
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil
    ) {
        let cachesURL = cachesDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let legacyDirectory = cachesURL
            .appendingPathComponent(ImageViewerAppIdentity.legacyBundleIdentifier, isDirectory: true)
            .appendingPathComponent("MotionPhoto", isDirectory: true)
        let currentDirectory = cachesURL
            .appendingPathComponent(ImageViewerAppIdentity.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("MotionPhoto", isDirectory: true)

        guard fileManager.fileExists(atPath: legacyDirectory.path),
              !fileManager.fileExists(atPath: currentDirectory.path) else {
            return
        }

        do {
            try fileManager.createDirectory(
                at: currentDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacyDirectory, to: currentDirectory)
        } catch {
            // Motion Photo movies are a disposable cache. The new cache will
            // be rebuilt on demand if the old directory cannot be moved.
        }
    }
}
