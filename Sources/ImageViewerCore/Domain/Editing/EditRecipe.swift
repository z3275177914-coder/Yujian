import Foundation

/// A non-destructive, versioned description of edits applied to one image.
public struct EditRecipe: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var operations: [EditOperation]

    public init(
        schemaVersion: Int = EditRecipe.currentSchemaVersion,
        operations: [EditOperation] = []
    ) {
        self.schemaVersion = max(1, schemaVersion)
        self.operations = operations
    }

    public static let empty = EditRecipe()

    public var enabledOperations: [EditOperation] {
        operations.filter(\.isEnabled)
    }

    public var isEmpty: Bool {
        enabledOperations.allSatisfy { operation in
            switch operation.kind {
            case .brightness: return operation.value == 0
            case .contrast, .saturation: return operation.value == 1
            case .sharpness, .exposure, .highlights, .shadows, .temperature, .tint,
                 .rotate, .straighten:
                return operation.value == 0
            case .flipHorizontal:
                return operation.value <= 0.5
            case .crop:
                guard let rect = operation.cropRect?.clamped else { return true }
                return rect.x == 0 && rect.y == 0 && rect.width == 1 && rect.height == 1
            }
        }
    }

    public func operation(id: String) -> EditOperation? {
        operations.first { $0.id == id }
    }

    public func replacing(_ operation: EditOperation) -> EditRecipe {
        var copy = self
        if let index = copy.operations.firstIndex(where: { $0.id == operation.id }) {
            copy.operations[index] = operation
        } else {
            copy.operations.append(operation)
        }
        return copy
    }

    public func setting(
        _ kind: EditOperationKind,
        value: Double,
        coalescingID: String? = nil
    ) -> EditRecipe {
        let id = coalescingID ?? kind.rawValue
        return replacing(.init(id: id, kind: kind, value: value))
    }

    /// Compatibility projection used by the current Core Image pipeline.
    public var imageAdjustments: ImageAdjustments {
        var result = ImageAdjustments.default
        for operation in enabledOperations {
            switch operation.kind {
            case .brightness: result.brightness = operation.value
            case .contrast: result.contrast = operation.value
            case .saturation: result.saturation = operation.value
            case .sharpness: result.sharpness = operation.value
            case .exposure: result.exposure = operation.value
            case .highlights: result.highlights = operation.value
            case .shadows: result.shadows = operation.value
            case .temperature: result.temperature = operation.value
            case .tint: result.tint = operation.value
            case .rotate, .flipHorizontal, .straighten, .crop: break
            }
        }
        return result.clamped
    }

    public var rotationDegrees: Double {
        enabledOperations
            .filter { $0.kind == .rotate || $0.kind == .straighten }
            .reduce(0) { $0 + $1.value }
    }

    public var isFlippedHorizontally: Bool {
        enabledOperations
            .filter { $0.kind == .flipHorizontal }
            .last?.value ?? 0 > 0.5
    }

    public var cropRect: EditCropRect? {
        enabledOperations.last(where: { $0.kind == .crop })?.cropRect?.clamped
    }

    public init(
        adjustments: ImageAdjustments,
        rotationDegrees: Double = 0,
        isFlippedHorizontally: Bool = false,
        cropRect: EditCropRect? = nil
    ) {
        var operations: [EditOperation] = []
        let values: [(EditOperationKind, Double, Double)] = [
            (.brightness, adjustments.brightness, 0),
            (.contrast, adjustments.contrast, 1),
            (.saturation, adjustments.saturation, 1),
            (.sharpness, adjustments.sharpness, 0),
            (.exposure, adjustments.exposure, 0),
            (.highlights, adjustments.highlights, 0),
            (.shadows, adjustments.shadows, 0),
            (.temperature, adjustments.temperature, 0),
            (.tint, adjustments.tint, 0)
        ]
        for (kind, value, neutral) in values where value != neutral {
            operations.append(.stable(kind, value: value))
        }
        if let cropRect = cropRect?.clamped,
           cropRect.width > 0,
           cropRect.height > 0,
           !(cropRect.x == 0 && cropRect.y == 0 && cropRect.width == 1 && cropRect.height == 1) {
            operations.append(.stable(.crop, cropRect: cropRect))
        }
        if rotationDegrees.isFinite,
           rotationDegrees.truncatingRemainder(dividingBy: 360) != 0 {
            operations.append(.stable(.rotate, value: rotationDegrees))
        }
        if isFlippedHorizontally {
            operations.append(.stable(.flipHorizontal, value: 1))
        }
        self.init(operations: operations)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case operations
        // These keys make decoding early pre-recipe adjustment snapshots safe.
        case brightness, contrast, saturation, sharpness
        case exposure, highlights, shadows, temperature, tint
        case rotationDegrees, isFlippedHorizontally
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        if let operations = try container.decodeIfPresent([EditOperation].self, forKey: .operations) {
            self.init(schemaVersion: min(EditRecipe.currentSchemaVersion, max(1, decodedVersion)), operations: operations)
            return
        }

        let adjustments = ImageAdjustments(
            brightness: try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0,
            contrast: try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 1,
            saturation: try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1,
            sharpness: try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0,
            exposure: try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0,
            highlights: try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0,
            shadows: try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0,
            temperature: try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0,
            tint: try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        )
        self.init(
            adjustments: adjustments,
            rotationDegrees: try container.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0,
            isFlippedHorizontally: try container.decodeIfPresent(Bool.self, forKey: .isFlippedHorizontally) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(operations, forKey: .operations)
    }
}

public extension ImageAdjustments {
    var editRecipe: EditRecipe {
        EditRecipe(adjustments: self)
    }

    init(editRecipe: EditRecipe) {
        self = editRecipe.imageAdjustments
    }
}
