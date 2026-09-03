import CoreGraphics

/// Keeps the Motion Photo click gesture separate from canvas pan and
/// double-click behavior. The view records pointer travel; this type decides
/// whether the completed gesture is safe to treat as playback.
public enum MotionPhotoClickReducer {
    public static let movementThreshold: CGFloat = 4

    public static func isSingleClick(
        clickCount: Int,
        maximumTravel: CGFloat,
        isEnabled: Bool,
        isInsideContent: Bool
    ) -> Bool {
        guard isEnabled,
              isInsideContent,
              clickCount == 1,
              maximumTravel.isFinite else {
            return false
        }
        return maximumTravel <= movementThreshold
    }
}
