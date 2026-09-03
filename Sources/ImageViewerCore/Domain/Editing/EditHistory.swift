import Foundation

/// Small value-type history that is easy to test and safe to move between
/// main-actor UI state and background export/AI jobs.
public struct EditHistory: Equatable, Sendable {
    public private(set) var current: EditRecipe
    public private(set) var undoStack: [EditRecipe]
    public private(set) var redoStack: [EditRecipe]

    private var lastCoalescingKey: String?

    public init(current: EditRecipe = .empty) {
        self.current = current
        self.undoStack = []
        self.redoStack = []
        self.lastCoalescingKey = nil
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func apply(
        _ recipe: EditRecipe,
        coalescingKey: String? = nil
    ) {
        guard recipe != current else {
            lastCoalescingKey = coalescingKey
            return
        }

        if let coalescingKey,
           coalescingKey == lastCoalescingKey,
           !undoStack.isEmpty {
            current = recipe
        } else {
            undoStack.append(current)
            current = recipe
            redoStack.removeAll(keepingCapacity: true)
        }
        lastCoalescingKey = coalescingKey
    }

    @discardableResult
    public mutating func undo() -> EditRecipe? {
        guard let previous = undoStack.popLast() else {
            return nil
        }
        redoStack.append(current)
        current = previous
        lastCoalescingKey = nil
        return current
    }

    @discardableResult
    public mutating func redo() -> EditRecipe? {
        guard let next = redoStack.popLast() else {
            return nil
        }
        undoStack.append(current)
        current = next
        lastCoalescingKey = nil
        return current
    }

    @discardableResult
    public mutating func reset() -> EditRecipe {
        apply(.empty)
        return current
    }
}
