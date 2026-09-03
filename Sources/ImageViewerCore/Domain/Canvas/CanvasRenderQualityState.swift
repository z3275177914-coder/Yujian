import Foundation

public enum CanvasRenderPhase: Equatable, Sendable {
    case interactive
    case settled
}

public struct CanvasSettledRenderRequest: Equatable, Sendable {
    public let revision: UInt64

    public init(revision: UInt64) {
        self.revision = revision
    }
}

/// Latest-wins state machine for cheap interactive frames and delayed settled
/// frames. Timers and layers stay in the AppKit view; this type owns validity.
public struct CanvasRenderQualityState: Equatable, Sendable {
    public private(set) var phase: CanvasRenderPhase
    public private(set) var revision: UInt64
    private var hasPendingSettledRequest: Bool

    public init(
        phase: CanvasRenderPhase = .settled,
        revision: UInt64 = 0
    ) {
        self.phase = phase
        self.revision = revision
        hasPendingSettledRequest = false
    }

    @discardableResult
    public mutating func beginInteraction() -> UInt64 {
        revision &+= 1
        phase = .interactive
        hasPendingSettledRequest = true
        return revision
    }

    public mutating func consumeSettledRequest() -> CanvasSettledRenderRequest? {
        guard hasPendingSettledRequest else {
            return nil
        }
        hasPendingSettledRequest = false
        phase = .settled
        return CanvasSettledRenderRequest(revision: revision)
    }

    public func accepts(_ request: CanvasSettledRenderRequest) -> Bool {
        request.revision == revision
    }

    public mutating func reset() {
        revision &+= 1
        phase = .settled
        hasPendingSettledRequest = false
    }
}
