import Testing
@testable import ImageViewerCore

@Test("Viewer image sessions invalidate older work")
@MainActor
func viewerImageSessionsInvalidateOlderWork() {
    let coordinator = ViewerSessionCoordinator()
    let first = coordinator.beginImageSession()
    let second = coordinator.beginImageSession()

    #expect(!coordinator.isCurrent(first))
    #expect(coordinator.isCurrent(second))
}

@Test("Viewer task slots cancel and invalidate previous tasks")
@MainActor
func viewerTaskSlotsCancelAndInvalidatePreviousTasks() {
    let coordinator = ViewerSessionCoordinator()
    let firstID = coordinator.start(.adjustment)
    let firstTask = Task {
        while !Task.isCancelled {
            await Task.yield()
        }
    }
    coordinator.track(firstTask, for: .adjustment)

    let secondID = coordinator.start(.adjustment)

    #expect(firstID != secondID)
    #expect(!coordinator.isCurrent(firstID, for: .adjustment))
    #expect(coordinator.isCurrent(secondID, for: .adjustment))
    #expect(firstTask.isCancelled)

    coordinator.cancelAll()
}
