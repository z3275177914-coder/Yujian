import Foundation
import Testing
@testable import ImageViewerCore

@Test("Directory scanner finds supported images and sorts by filename")
func directoryScannerFindsAndSortsImages() async throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    try Data().write(to: temporaryDirectory.appendingPathComponent("zebra.JPG"))
    try Data().write(to: temporaryDirectory.appendingPathComponent("apple.png"))
    try Data().write(to: temporaryDirectory.appendingPathComponent("notes.txt"))

    let scanner = DirectoryScanner()
    let assets = await scanner.scan(directoryURL: temporaryDirectory)

    #expect(assets.map(\.filename) == ["apple.png", "zebra.JPG"])
}

@Test("Directory scanner does not recurse into subdirectories")
func directoryScannerDoesNotRecurse() async throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let nestedDirectory = temporaryDirectory.appendingPathComponent("Nested", isDirectory: true)
    try FileManager.default.createDirectory(
        at: nestedDirectory,
        withIntermediateDirectories: true
    )
    try Data().write(to: nestedDirectory.appendingPathComponent("nested.png"))

    let scanner = DirectoryScanner()
    let assets = await scanner.scan(directoryURL: temporaryDirectory)

    #expect(assets.isEmpty)
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImageViewerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}
