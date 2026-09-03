import Foundation
import Testing
@testable import ImageViewerCore

@Test("Edit recipes round-trip their schema, operation IDs and disabled state")
func editRecipeRoundTrips() throws {
    let recipe = EditRecipe(operations: [
        .init(id: "brightness", kind: .brightness, value: 0.25),
        .init(id: "crop-1", kind: .crop, cropRect: EditCropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6), isEnabled: false)
    ])

    let data = try JSONEncoder().encode(recipe)
    let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)

    #expect(decoded == recipe)
    #expect(decoded.operation(id: "crop-1")?.isEnabled == false)
    #expect(decoded.imageAdjustments.brightness == 0.25)
}

@Test("Edit recipes migrate legacy adjustment snapshots")
func editRecipeMigratesLegacyAdjustmentSnapshot() throws {
    let data = #"{"brightness":0.2,"contrast":1.4,"rotationDegrees":90,"isFlippedHorizontally":true}"#.data(using: .utf8)!
    let recipe = try JSONDecoder().decode(EditRecipe.self, from: data)

    #expect(recipe.imageAdjustments.brightness == 0.2)
    #expect(recipe.imageAdjustments.contrast == 1.4)
    #expect(recipe.rotationDegrees == 90)
    #expect(recipe.isFlippedHorizontally)
    #expect(recipe.schemaVersion == EditRecipe.currentSchemaVersion)
}

@Test("Edit recipe projections respect operation order and enablement")
func editRecipeProjectionRespectsOrder() {
    let recipe = EditRecipe(operations: [
        .init(id: "first", kind: .brightness, value: 0.1),
        .init(id: "second", kind: .brightness, value: 0.8),
        .init(id: "disabled", kind: .brightness, value: -1, isEnabled: false),
        .init(id: "rotate-a", kind: .rotate, value: 90),
        .init(id: "rotate-b", kind: .straighten, value: 2)
    ])

    #expect(recipe.imageAdjustments.brightness == 0.8)
    #expect(recipe.rotationDegrees == 92)
}

@Test("Edit history coalesces slider updates and supports undo redo reset")
func editHistorySupportsUndoRedoAndReset() {
    var history = EditHistory()
    history.apply(EditRecipe(operations: [.stable(.brightness, value: 0.1)]), coalescingKey: "brightness")
    history.apply(EditRecipe(operations: [.stable(.brightness, value: 0.2)]), coalescingKey: "brightness")

    #expect(history.undoStack.count == 1)
    #expect(history.current.imageAdjustments.brightness == 0.2)

    _ = history.undo()
    #expect(history.current.isEmpty)
    _ = history.redo()
    #expect(history.current.imageAdjustments.brightness == 0.2)

    _ = history.reset()
    #expect(history.current.isEmpty)
    #expect(history.canUndo)
}
