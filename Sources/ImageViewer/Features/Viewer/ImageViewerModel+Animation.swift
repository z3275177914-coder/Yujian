import AppKit
import Foundation
import ImageViewerCore

@MainActor
extension ImageViewerModel {
    func isAnimated(_ asset: ImageAsset) -> Bool {
        asset.fileExtension == "gif" || asset.fileExtension == "webp"
    }

    func startAnimation(_ animation: AnimatedImageSession, assetID: String) {
        sessionCoordinator.cancel(.animation)
        let animationTaskID = sessionCoordinator.start(.animation)
        let animationTask = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                let duration = min(10, max(0.02, animation.duration(at: index)))
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(duration * 1_000_000_000)
                    )
                } catch {
                    return
                }

                guard !Task.isCancelled,
                      let self,
                      self.sessionCoordinator.isCurrent(animationTaskID, for: .animation) else {
                    return
                }
                guard self.currentAsset?.id == assetID else {
                    return
                }

                index = (index + 1) % animation.frameCount
                guard let frame = await animation.image(at: index) else {
                    return
                }
                guard !Task.isCancelled,
                      self.sessionCoordinator.isCurrent(animationTaskID, for: .animation),
                      self.currentAsset?.id == assetID else {
                    return
                }
                // A pristine animation can update the AppKit canvas directly;
                // publishing every frame through ImageViewerModel rebuilds
                // the SwiftUI workbench and starves zoom/pan input. Keep the
                // old model-driven path only while preview edits are active.
                if self.editRecipe.isEmpty {
                    self.animatedFrameStore.update(frame)
                } else {
                    self.updateCurrentImageForAnimation(frame)
                }
            }
        }
        sessionCoordinator.track(animationTask, for: .animation)
    }
}
