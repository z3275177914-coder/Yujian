import Testing
@testable import ImageViewerCore

@Test("Settled requests merge into the latest interaction")
func settledRequestsMergeIntoTheLatestInteraction() {
    var state = CanvasRenderQualityState()
    state.beginInteraction()
    state.beginInteraction()
    state.beginInteraction()

    let request = state.consumeSettledRequest()

    #expect(request?.revision == state.revision)
    #expect(state.phase == .settled)
    #expect(state.consumeSettledRequest() == nil)
}

@Test("An older settled result is discarded after a new interaction")
func olderSettledResultIsDiscardedAfterANewInteraction() {
    var state = CanvasRenderQualityState()
    state.beginInteraction()
    let oldRequest = state.consumeSettledRequest()!

    state.beginInteraction()

    #expect(!state.accepts(oldRequest))
    #expect(state.accepts(CanvasSettledRenderRequest(revision: state.revision)))
}

@Test("Continuous input produces one final settled request")
func continuousInputProducesOneFinalSettledRequest() {
    var state = CanvasRenderQualityState()
    for _ in 0..<120 {
        state.beginInteraction()
    }

    let request = state.consumeSettledRequest()

    #expect(request != nil)
    #expect(state.consumeSettledRequest() == nil)
}
