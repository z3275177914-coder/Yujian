import Foundation
import Testing
@testable import ImageViewerCore

@Test("玉鉴使用稳定的公开应用身份")
func publicApplicationIdentityIsStable() {
    #expect(ImageViewerAppIdentity.bundleIdentifier == "io.github.z3275177914-coder.yujian")
    #expect(ImageViewerAppIdentity.legacyBundleIdentifier == "com.imageviewer.mac")
    #expect(ImageViewerAppIdentity.urlScheme == "yujian")
    #expect(ImageViewerAppIdentity.legacyURLScheme == "imageviewer")
    #expect(ImageViewerAppIdentity.acceptsURLScheme("YUJIAN"))
    #expect(ImageViewerAppIdentity.acceptsURLScheme("IMAGEVIEWER"))
    #expect(!ImageViewerAppIdentity.acceptsURLScheme("other-app"))
}

@Test("Bundle ID 迁移保留旧设置并优先采用新设置")
func bundleIdentityMigrationPreservesDefaults() {
    let legacyDomainName = "ImageViewerIdentityLegacy-\(UUID().uuidString)"
    let currentDomainName = "ImageViewerIdentityCurrent-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: "ImageViewerIdentityTests-\(UUID().uuidString)")!
    defer {
        defaults.removePersistentDomain(forName: legacyDomainName)
        defaults.removePersistentDomain(forName: currentDomainName)
    }

    defaults.setPersistentDomain([
        "ImageViewer.mouseSensitivity": 0.75,
        "legacy-only": "preserved"
    ], forName: legacyDomainName)
    defaults.setPersistentDomain([
        "ImageViewer.mouseSensitivity": 1.5,
        "current-only": true
    ], forName: currentDomainName)

    AppIdentityMigration.migrateUserDefaults(
        in: defaults,
        legacyDomainName: legacyDomainName,
        currentDomainName: currentDomainName
    )

    let migrated = defaults.persistentDomain(forName: currentDomainName) ?? [:]
    #expect((migrated["ImageViewer.mouseSensitivity"] as? Double) == 1.5)
    #expect((migrated["legacy-only"] as? String) == "preserved")
    #expect((migrated["current-only"] as? Bool) == true)
    #expect((migrated["ImageViewer.appIdentityMigration.bundleIdentifier.v1"] as? Bool) == true)
}

@Test("旧动态照片缓存迁移到新 Bundle ID 目录")
func legacyMotionPhotoCacheMovesToNewIdentity() throws {
    let cachesDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImageViewerIdentityCache-\(UUID().uuidString)", isDirectory: true)
    let legacyDirectory = cachesDirectory
        .appendingPathComponent(ImageViewerAppIdentity.legacyBundleIdentifier, isDirectory: true)
        .appendingPathComponent("MotionPhoto", isDirectory: true)
    let legacyFile = legacyDirectory.appendingPathComponent("sample.mp4")
    try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
    try Data("cached motion photo".utf8).write(to: legacyFile)
    defer { try? FileManager.default.removeItem(at: cachesDirectory) }

    AppIdentityMigration.migrateMotionPhotoCache(cachesDirectory: cachesDirectory)

    let currentFile = cachesDirectory
        .appendingPathComponent(ImageViewerAppIdentity.bundleIdentifier, isDirectory: true)
        .appendingPathComponent("MotionPhoto", isDirectory: true)
        .appendingPathComponent("sample.mp4")
    #expect(FileManager.default.fileExists(atPath: currentFile.path))
    #expect(!FileManager.default.fileExists(atPath: legacyDirectory.path))
}
