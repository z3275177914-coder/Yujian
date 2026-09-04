import AVFoundation
import AppKit
import ImageViewerCore

/// Owns the optional video layer for the currently selected Motion Photo.
/// AVFoundation keeps video frames on its native rendering path; SwiftUI only
/// receives the lightweight visibility callback used by the existing canvas.
@MainActor
final class MotionPhotoPlaybackController: NSObject {
    enum State: Equatable {
        case idle
        case preparing
        case playing
        case paused
        case failed
    }

    let layer = AVPlayerLayer()

    private(set) var state: State = .idle
    private(set) var info: MotionPhotoInfo?
    private(set) var isPlaybackVisible = false
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var readyObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var playbackGeneration: UInt64 = 0
    private var preparationTask: Task<Void, Never>?
    private var temporaryFallbackURL: URL?

    var onPlaybackVisibilityChange: ((Bool) -> Void)?

    var hasMotionPhoto: Bool {
        info != nil
    }

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        layer.masksToBounds = true
        layer.isHidden = true
    }

    func update(info: MotionPhotoInfo?) {
        guard self.info != info else {
            return
        }
        stopPlayback()
        self.info = info
    }

    func togglePlayback() {
        guard player != nil else {
            play()
            return
        }
        switch state {
        case .playing:
            pausePlayback()
        case .paused:
            player?.play()
            state = .playing
        case .idle, .failed:
            play()
        case .preparing:
            return
        }
    }

    func play() {
        guard let info else {
            failPlayback()
            return
        }
        guard FileManager.default.fileExists(atPath: info.videoSource.sourceURL.path) else {
            failPlayback()
            return
        }

        if let player, state == .paused {
            player.play()
            state = .playing
            return
        }
        guard player == nil else {
            return
        }

        stopPlayback()
        PerformanceLog.event("MotionPhotoPlaybackStart")
        let generation = playbackGeneration
        state = .preparing

        switch info.videoSource {
        case let .external(videoURL):
            startPlayer(
                videoURL: videoURL,
                temporaryVideoURL: nil,
                generation: generation
            )

        case let .embedded(sourceURL, offset, length):
            preparationTask = Task { @MainActor [weak self] in
                do {
                    let extractedURL = try await MotionPhotoExtractor
                        .extractEmbeddedVideo(
                            from: sourceURL,
                            offset: offset,
                            length: length
                        )
                    guard !Task.isCancelled else {
                        if !MotionPhotoCache.isManagedURL(extractedURL) {
                            try? FileManager.default.removeItem(at: extractedURL)
                        }
                        return
                    }
                    guard let self,
                          self.playbackGeneration == generation,
                          self.info == info else {
                        if !MotionPhotoCache.isManagedURL(extractedURL) {
                            try? FileManager.default.removeItem(at: extractedURL)
                        }
                        return
                    }
                    self.preparationTask = nil
                    self.startPlayer(
                        videoURL: extractedURL,
                        temporaryVideoURL: MotionPhotoCache.isManagedURL(extractedURL)
                            ? nil
                            : extractedURL,
                        generation: generation
                    )
                } catch {
                    guard !Task.isCancelled else {
                        return
                    }
                    self?.failPlayback(generation: generation)
                }
            }
        }
    }

    func pausePlayback() {
        guard let player else {
            return
        }
        player.pause()
        state = .paused
    }

    private func startPlayer(
        videoURL: URL,
        temporaryVideoURL: URL?,
        generation: UInt64
    ) {
        guard playbackGeneration == generation,
              player == nil else {
            if let temporaryVideoURL {
                try? FileManager.default.removeItem(at: temporaryVideoURL)
            }
            return
        }

        let item = AVPlayerItem(url: videoURL)
        let itemID = ObjectIdentifier(item)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        // Preserve the existing viewer's silent-preview policy. No custom
        // audio engine is introduced for Motion Photos.
        player.isMuted = true

        self.player = player
        self.temporaryFallbackURL = temporaryVideoURL
        state = .preparing
        layer.player = player
        layer.isHidden = true

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishPlayback(generation: generation)
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.failPlayback(generation: generation)
            }
        }
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            switch item.status {
            case .readyToPlay:
                Task { @MainActor [weak self] in
                    guard let self,
                          self.playbackGeneration == generation,
                          self.player?.currentItem.map(ObjectIdentifier.init) == itemID else {
                        return
                    }
                    self.showReadyFrame()
                }
            case .failed:
                Task { @MainActor [weak self] in
                    self?.failPlayback(generation: generation)
                }
            default:
                break
            }
        }
        readyObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackGeneration == generation else {
                    return
                }
                self.showReadyFrame()
            }
        }

        player.play()
    }

    func stopPlayback() {
        playbackGeneration &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        let wasVisible = isPlaybackVisible
        removeObservers()
        player?.pause()
        player = nil
        layer.player = nil
        layer.isHidden = true
        removeTemporaryVideo()
        isPlaybackVisible = false
        state = .idle
        if wasVisible {
            onPlaybackVisibilityChange?(false)
        }
    }

    private func showReadyFrame() {
        guard player != nil, !isPlaybackVisible else {
            return
        }
        state = .playing
        isPlaybackVisible = true
        layer.isHidden = false
        onPlaybackVisibilityChange?(true)
        PerformanceLog.event("MotionPhotoFirstFrame")
    }

    private func finishPlayback(generation: UInt64) {
        guard playbackGeneration == generation, player != nil else {
            return
        }
        PerformanceLog.event("MotionPhotoPlaybackCompleted")
        stopPlayback()
    }

    private func failPlayback(generation: UInt64? = nil) {
        if let generation,
           playbackGeneration != generation {
            return
        }
        playbackGeneration &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        let wasVisible = isPlaybackVisible
        removeObservers()
        player?.pause()
        player = nil
        layer.player = nil
        layer.isHidden = true
        removeTemporaryVideo()
        isPlaybackVisible = false
        state = .failed
        if wasVisible {
            onPlaybackVisibilityChange?(false)
        }
        PerformanceLog.event("MotionPhotoPlaybackFailed")
    }

    private func removeTemporaryVideo() {
        guard let temporaryFallbackURL else {
            return
        }
        try? FileManager.default.removeItem(at: temporaryFallbackURL)
        self.temporaryFallbackURL = nil
    }

    private func removeObservers() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        endObserver = nil
        failureObserver = nil
        readyObservation = nil
        itemStatusObservation = nil
    }
}
