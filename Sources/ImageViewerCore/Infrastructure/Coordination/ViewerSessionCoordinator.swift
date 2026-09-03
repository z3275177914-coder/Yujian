import Foundation

public enum ViewerTaskSlot: Hashable, Sendable {
    case scan
    case image
    case metadata
    case animation
    case motionPhoto
    case adjustment
    case inspection
    case ai
    case export
}

public struct ViewerImageSessionID: Equatable, Sendable {
    fileprivate let rawValue: UInt64
}

public struct ViewerTaskID: Equatable, Sendable {
    fileprivate let rawValue: UInt64
}

/// Owns cancellable work associated with one viewer session.
///
/// The model remains the facade used by SwiftUI, while all viewer-owned tasks
/// are invalidated through this coordinator. This prevents an old image,
/// metadata request, or preview render from writing into a newer selection.
@MainActor
public final class ViewerSessionCoordinator {
    private var nextID: UInt64 = 0
    private var tasks: [ViewerTaskSlot: Task<Void, Never>] = [:]
    private var currentTaskIDs: [ViewerTaskSlot: ViewerTaskID] = [:]
    private var currentImageSessionID: ViewerImageSessionID?

    public init() {}

    public func beginImageSession() -> ViewerImageSessionID {
        cancel(.image)
        cancel(.metadata)
        cancel(.animation)
        cancel(.motionPhoto)
        cancel(.adjustment)
        cancel(.inspection)
        cancel(.ai)

        let sessionID = ViewerImageSessionID(rawValue: nextIdentifier())
        currentImageSessionID = sessionID
        return sessionID
    }

    public func isCurrent(_ sessionID: ViewerImageSessionID) -> Bool {
        currentImageSessionID == sessionID
    }

    @discardableResult
    public func start(_ slot: ViewerTaskSlot) -> ViewerTaskID {
        cancel(slot)
        let taskID = ViewerTaskID(rawValue: nextIdentifier())
        currentTaskIDs[slot] = taskID
        return taskID
    }

    public func isCurrent(
        _ taskID: ViewerTaskID,
        for slot: ViewerTaskSlot
    ) -> Bool {
        currentTaskIDs[slot] == taskID
    }

    public func track(
        _ task: Task<Void, Never>,
        for slot: ViewerTaskSlot
    ) {
        tasks[slot] = task
    }

    public func cancel(_ slot: ViewerTaskSlot) {
        tasks[slot]?.cancel()
        tasks.removeValue(forKey: slot)
        currentTaskIDs.removeValue(forKey: slot)
    }

    public func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        currentTaskIDs.removeAll()
        currentImageSessionID = nil
    }

    private func nextIdentifier() -> UInt64 {
        nextID &+= 1
        return nextID
    }
}
