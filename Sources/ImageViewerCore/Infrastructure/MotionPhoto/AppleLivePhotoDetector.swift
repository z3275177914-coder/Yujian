import AVFoundation
import Foundation
import ImageIO

/// Pairs an Apple Live Photo still with its MOV. Content identifiers are
/// authoritative; same-stem pairing is retained only as the documented
/// fallback for files whose metadata has been stripped.
public struct AppleLivePhotoDetector: MotionPhotoDetecting, Sendable {
    public init() {}

    public func detect(url: URL) async throws -> MotionPhotoInfo? {
        try Task.checkCancellation()
        let stillURL = url.standardizedFileURL
        guard AndroidMotionPhotoDetector.isCandidateStill(stillURL) else {
            return nil
        }

        let stillIdentifier = await Task.detached(priority: .utility) {
            Self.stillContentIdentifier(for: stillURL)
        }.value
        let movieURLs = Self.movieURLs(in: stillURL.deletingLastPathComponent())

        if let stillIdentifier {
            for movieURL in movieURLs {
                try Task.checkCancellation()
                do {
                    guard let movieIdentifier = try await Self.movieContentIdentifier(
                        for: movieURL
                    ), movieIdentifier == stillIdentifier,
                    try await Self.isPlayable(movieURL) else {
                        continue
                    }
                    return MotionPhotoInfo(
                        format: .appleLivePhoto,
                        videoSource: .external(movieURL)
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
            }
            // A parsed still identifier with no matching MOV is not a valid
            // fallback case: pairing an unrelated same-stem movie is worse
            // than leaving the still image static.
            return nil
        }

        // Identifier-free exports can still be paired by the established
        // same-stem convention, but no other movie in the directory is guessed.
        guard let fallbackURL = Self.sameStemMovieURL(for: stillURL),
              try await Self.isPlayable(fallbackURL) else {
            return nil
        }
        return MotionPhotoInfo(
            format: .appleLivePhoto,
            videoSource: .external(fallbackURL),
            pairingConfidence: .fallback
        )
    }

    static func movieURLs(in directoryURL: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { url in
                guard ["mov"].contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
                    return false
                }
                return values.isRegularFile == true
            }
            .sorted { $0.path < $1.path }
    }

    static func sameStemMovieURL(for stillURL: URL) -> URL? {
        let baseURL = stillURL.deletingPathExtension()
        return [
            baseURL.appendingPathExtension("mov"),
            baseURL.appendingPathExtension("MOV")
        ].first { candidate in
            guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]) else {
                return false
            }
            return values.isRegularFile == true
        }
    }

    private static func stillContentIdentifier(for url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as NSDictionary? else {
            return nil
        }

        let makerApple = properties.object(
            forKey: kCGImagePropertyMakerAppleDictionary
        ) as? NSDictionary
        let knownKeys = [
            "17",
            "AssetIdentifier",
            "assetIdentifier",
            "ContentIdentifier",
            "contentIdentifier"
        ]
        for key in knownKeys {
            if let value = normalizedString(makerApple?.object(forKey: key)) {
                return value
            }
        }
        return identifier(in: makerApple)
    }

    private static func movieContentIdentifier(for url: URL) async throws -> String? {
        let asset = AVURLAsset(url: url)
        let metadata = try await asset.load(.metadata)
        for item in metadata {
            if item.identifier == AVMetadataIdentifier.quickTimeMetadataContentIdentifier,
               let value = normalizedString(try await item.load(.value)) {
                return value
            }
            let key = String(describing: item.key).lowercased()
            if key.contains("content.identifier"),
               let value = normalizedString(try await item.load(.value)) {
                return value
            }
        }
        return nil
    }

    private static func isPlayable(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        return try await asset.load(.isPlayable)
    }

    private static func identifier(in dictionary: NSDictionary?) -> String? {
        guard let dictionary else {
            return nil
        }
        for (key, value) in dictionary {
            let keyText = String(describing: key).lowercased()
            if keyText.contains("identifier"),
               let identifier = normalizedString(value) {
                return identifier
            }
            if let nested = value as? NSDictionary,
               let identifier = identifier(in: nested) {
                return identifier
            }
        }
        return nil
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
