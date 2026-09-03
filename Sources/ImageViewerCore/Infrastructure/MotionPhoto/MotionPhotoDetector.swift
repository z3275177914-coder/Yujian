import Foundation

public protocol MotionPhotoDetecting: Sendable {
    func detect(url: URL) async throws -> MotionPhotoInfo?
}

/// Runs format detectors in the order defined by the Motion Photo spec. Each
/// detector only returns data; UI state remains owned by ImageViewerModel.
public actor MotionPhotoDetector {
    private let detectors: [any MotionPhotoDetecting]

    public init() {
        detectors = [
            AndroidMotionPhotoDetector(),
            LegacyGoogleMotionPhotoDetector(),
            SamsungMotionPhotoDetector(),
            AppleLivePhotoDetector()
        ]
    }

    public init(detectors: [any MotionPhotoDetecting]) {
        self.detectors = detectors
    }

    public func detect(url: URL) async throws -> MotionPhotoInfo? {
        for detector in detectors {
            try Task.checkCancellation()
            do {
                if let info = try await detector.detect(url: url) {
                    return info
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A malformed enhancement must fall through to the next
                // detector and never prevent the still image from showing.
                PerformanceLog.event("MotionPhotoDetectorSkipped")
            }
        }
        return nil
    }
}
