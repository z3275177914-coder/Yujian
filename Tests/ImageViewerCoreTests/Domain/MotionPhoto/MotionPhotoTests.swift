import CoreMedia
import Foundation
import Testing
@testable import ImageViewerCore

@Test("Apple fallback pairing keeps the movie out of the image asset list")
func appleLivePhotoFallbackFindsSameStemMovie() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let stillURL = directory.appendingPathComponent("IMG_0001.HEIC")
    let movieURL = directory.appendingPathComponent("IMG_0001.MOV")
    try Data().write(to: stillURL)
    try Data().write(to: movieURL)

    #expect(
        AppleLivePhotoDetector.sameStemMovieURL(for: stillURL)?.path.lowercased()
            == movieURL.path.lowercased()
    )
    #expect(ImageAsset.isSupportedImage(stillURL))
    #expect(!ImageAsset.isSupportedImage(movieURL))
}

@Test("Motion Photo model keeps only the proposed format, source and timestamp")
func motionPhotoInfoUsesUnifiedModel() {
    let sourceURL = URL(fileURLWithPath: "/tmp/motion.jpg")
    let info = MotionPhotoInfo(
        format: .android,
        videoSource: .embedded(
            sourceURL: sourceURL,
            offset: 512,
            length: 256
        ),
        presentationTimestamp: CMTime(value: 123_456, timescale: 1_000_000)
    )

    #expect(info.format == .android)
    #expect(info.videoSource.sourceURL == sourceURL)
    #expect(info.presentationTimestamp?.value == 123_456)
    #expect(info.presentationTimestamp?.timescale == 1_000_000)
    #expect(info.pairingConfidence == .verified)
}

@Test("Android Motion Photo detector reads the current XMP container fields")
func androidMotionPhotoDetectorReadsMetadata() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let xmp = Data(
        #"<rdf:Description Camera:MotionPhoto="1" Camera:MotionPhotoVersion="1" Camera:MotionPhotoOffset="24" Camera:MotionPhotoPresentationTimestampUs="123456"/>"#
            .utf8
    )
    var video = Data(repeating: 0, count: 24)
    video.replaceSubrange(4..<8, with: Data("ftyp".utf8))
    var motionPhoto = xmp
    motionPhoto.append(video)
    let url = directory.appendingPathComponent("motion.jpg")
    try motionPhoto.write(to: url)

    let info = try await AndroidMotionPhotoDetector().detect(url: url)

    #expect(info?.format == .android)
    #expect(
        info?.videoSource
            == .embedded(
                sourceURL: url.standardizedFileURL,
                offset: UInt64(xmp.count),
                length: UInt64(video.count)
            )
    )
    #expect(info?.presentationTimestamp?.value == 123_456)
}

@Test("Legacy Google MicroVideo is detected by its independent detector")
func legacyGoogleMotionPhotoDetectorReadsMetadata() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let xmp = Data(
        #"<rdf:Description GCamera:MicroVideo="1" GCamera:MicroVideoOffset="16" GCamera:MicroVideoPresentationTimestampUs="8000"/>"#
            .utf8
    )
    var video = Data(repeating: 0, count: 16)
    video.replaceSubrange(4..<8, with: Data("ftyp".utf8))
    var file = xmp
    file.append(video)
    let url = directory.appendingPathComponent("legacy.jpg")
    try file.write(to: url)

    let info = try await LegacyGoogleMotionPhotoDetector().detect(url: url)

    #expect(info?.format == .android)
    #expect(info?.presentationTimestamp?.value == 8_000)
    #expect(
        info?.videoSource
            == .embedded(
                sourceURL: url.standardizedFileURL,
                offset: UInt64(xmp.count),
                length: UInt64(video.count)
            )
    )
}

@Test("Samsung Motion Photo marker can identify a trailing MP4")
func samsungMotionPhotoDetectorFindsTrailingVideo() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let metadata = Data(
        #"<rdf:Description Samsung:MotionPhoto_Data="1" Samsung:MotionPhotoPresentationTimestampUs="4000"/>"#
            .utf8
    )
    var file = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
    file.append(metadata)
    let videoOffset = file.count
    file.append(Data([0, 0, 0, 0]))
    file.append(Data("ftyp".utf8))
    file.append(Data(repeating: 0, count: 12))
    let url = directory.appendingPathComponent("samsung.jpg")
    try file.write(to: url)

    let info = try await SamsungMotionPhotoDetector().detect(url: url)

    #expect(info?.format == .samsung)
    #expect(info?.presentationTimestamp?.value == 4_000)
    #expect(
        info?.videoSource
            == .embedded(
                sourceURL: url.standardizedFileURL,
                offset: UInt64(videoOffset),
                length: UInt64(file.count - videoOffset)
            )
    )
}

@Test("Detector aggregator keeps ordinary JPGs as still images")
func motionPhotoDetectorDistinguishesOrdinaryJPG() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let ordinaryJPGURL = directory.appendingPathComponent("ordinary.jpg")
    try Data("ordinary jpeg bytes".utf8).write(to: ordinaryJPGURL)

    let detector = MotionPhotoDetector()
    let info = try await detector.detect(url: ordinaryJPGURL)

    #expect(info == nil)
}

@Test("Embedded Motion Photo extraction copies only the declared range and caches it")
func embeddedMotionPhotoExtractionUsesRangeCache() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let containerURL = directory.appendingPathComponent("motion.jpg")
    let cacheURL = directory.appendingPathComponent("cache", isDirectory: true)
    let prefix = Data("jpeg-prefix".utf8)
    let video = Data("video-ftyp-and-media".utf8)
    var container = prefix
    container.append(video)
    try container.write(to: containerURL)
    let cache = MotionPhotoCache(directoryURL: cacheURL)

    let extractedURL = try await MotionPhotoExtractor.extractEmbeddedVideo(
        from: containerURL,
        offset: UInt64(prefix.count),
        length: UInt64(video.count),
        cache: cache
    )
    let secondURL = try await MotionPhotoExtractor.extractEmbeddedVideo(
        from: containerURL,
        offset: UInt64(prefix.count),
        length: UInt64(video.count),
        cache: cache
    )

    #expect(extractedURL == secondURL)
    #expect(try Data(contentsOf: extractedURL) == video)

    var changedContainer = container
    changedContainer.append(0x00)
    try changedContainer.write(to: containerURL)
    let changedURL = try await MotionPhotoExtractor.extractEmbeddedVideo(
        from: containerURL,
        offset: UInt64(prefix.count),
        length: UInt64(video.count),
        cache: cache
    )
    #expect(changedURL != extractedURL)
}

@Test("Embedded Motion Photo extraction rejects invalid ranges")
func embeddedMotionPhotoExtractionRejectsInvalidRange() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("motion.jpg")
    try Data(repeating: 0, count: 8).write(to: sourceURL)

    var didThrow = false
    do {
        _ = try await MotionPhotoExtractor.extractEmbeddedVideo(
            from: sourceURL,
            offset: 7,
            length: 2,
            cache: MotionPhotoCache(
                directoryURL: directory.appendingPathComponent("cache")
            )
        )
    } catch {
        didThrow = true
    }
    #expect(didThrow)
    #expect(!MotionPhotoExtractor.isValidRange(fileSize: 8, offset: 7, length: 2))
}

@Test("Motion Photo click reducer separates clicks from pans and double clicks")
func motionPhotoClickReducer() {
    #expect(
        MotionPhotoClickReducer.isSingleClick(
            clickCount: 1,
            maximumTravel: 2,
            isEnabled: true,
            isInsideContent: true
        )
    )
    #expect(
        !MotionPhotoClickReducer.isSingleClick(
            clickCount: 1,
            maximumTravel: 5,
            isEnabled: true,
            isInsideContent: true
        )
    )
    #expect(
        !MotionPhotoClickReducer.isSingleClick(
            clickCount: 2,
            maximumTravel: 0,
            isEnabled: true,
            isInsideContent: true
        )
    )
    #expect(
        !MotionPhotoClickReducer.isSingleClick(
            clickCount: 1,
            maximumTravel: 0,
            isEnabled: true,
            isInsideContent: false
        )
    )
}

@Test("Changing image sessions cancels Motion Photo detection")
@MainActor
func motionPhotoDetectionIsSessionScoped() {
    let coordinator = ViewerSessionCoordinator()
    let taskID = coordinator.start(.motionPhoto)
    let task = Task {
        while !Task.isCancelled {
            await Task.yield()
        }
    }
    coordinator.track(task, for: .motionPhoto)

    _ = coordinator.beginImageSession()

    #expect(task.isCancelled)
    #expect(!coordinator.isCurrent(taskID, for: .motionPhoto))
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImageViewerMotionPhotoTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}
