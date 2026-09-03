import Foundation
import Testing
@testable import ImageViewerCore

@Test("Directory session streams a large directory in bounded batches")
func directorySessionStreamsLargeDirectoryInBatches() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    for index in 0..<10_000 {
        let filename = String(format: "image-%05d.png", index)
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent(filename).path,
            contents: nil
        )
    }

    let session = DirectorySession()
    let stream = await session.start(directoryURL: directory, batchSize: 256)
    var assetCount = 0
    var batchCount = 0
    var maximumBatchSize = 0

    for await batch in stream {
        if batch.isComplete {
            break
        }
        assetCount += batch.assets.count
        batchCount += 1
        maximumBatchSize = max(maximumBatchSize, batch.assets.count)
    }

    #expect(assetCount == 10_000)
    #expect(batchCount > 1)
    #expect(maximumBatchSize <= 256)
}

@Test("Starting a directory session invalidates its older revision")
func startingDirectorySessionInvalidatesOlderRevision() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    FileManager.default.createFile(
        atPath: directory.appendingPathComponent("one.png").path,
        contents: nil
    )

    let session = DirectorySession()
    let firstStream = await session.start(directoryURL: directory, batchSize: 1)
    var firstIterator = firstStream.makeAsyncIterator()
    let firstBatch = await firstIterator.next()
    let firstRevision = try #require(firstBatch?.revision)

    let secondStream = await session.start(directoryURL: directory, batchSize: 1)
    var secondIterator = secondStream.makeAsyncIterator()
    let secondBatch = await secondIterator.next()
    let secondRevision = try #require(secondBatch?.revision)

    #expect(firstRevision != secondRevision)
    #expect(await !session.isCurrent(firstRevision))
    #expect(await session.isCurrent(secondRevision))
}

@Test("Directory scanner uses natural filename order in progressive batches")
func directoryScannerUsesNaturalFilenameOrder() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for filename in ["image-10.png", "image-2.png", "image-1.png"] {
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent(filename).path,
            contents: nil
        )
    }

    let session = DirectorySession()
    let stream = await session.start(directoryURL: directory, batchSize: 1)
    var names: [String] = []
    for await batch in stream {
        if batch.isComplete {
            break
        }
        names.append(contentsOf: batch.assets.map(\.filename))
    }

    #expect(names == ["image-1.png", "image-2.png", "image-10.png"])
}

@Test("Directory watcher emits an invalidation when contents change")
func directoryWatcherEmitsInvalidation() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let signal = DirectoryChangeSignal()
    let watcher = DirectoryWatcher(directoryURL: directory) {
        Task {
            await signal.record()
        }
    }
    watcher.start()
    FileManager.default.createFile(
        atPath: directory.appendingPathComponent("changed.png").path,
        contents: nil
    )

    try await Task.sleep(nanoseconds: 500_000_000)
    watcher.cancel()

    #expect(await signal.count > 0)
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImageViewerDirectoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private actor DirectoryChangeSignal {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
