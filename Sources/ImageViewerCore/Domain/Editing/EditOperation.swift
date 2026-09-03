import CoreGraphics
import Foundation

/// The small, serializable vocabulary shared by preview, export and AI input.
public enum EditOperationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case brightness
    case contrast
    case saturation
    case sharpness
    case exposure
    case highlights
    case shadows
    case temperature
    case tint
    case rotate
    case flipHorizontal
    case straighten
    case crop

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .brightness: return "亮度"
        case .contrast: return "对比度"
        case .saturation: return "饱和度"
        case .sharpness: return "锐度"
        case .exposure: return "曝光"
        case .highlights: return "高光"
        case .shadows: return "阴影"
        case .temperature: return "色温"
        case .tint: return "色调"
        case .rotate: return "旋转"
        case .flipHorizontal: return "水平翻转"
        case .straighten: return "拉直"
        case .crop: return "裁剪"
        }
    }
}

public struct EditCropRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(rect: CGRect) {
        self.init(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    public var clamped: EditCropRect {
        let x = min(1, max(0, x.isFinite ? x : 0))
        let y = min(1, max(0, y.isFinite ? y : 0))
        return EditCropRect(
            x: x,
            y: y,
            width: min(max(0, width.isFinite ? width : 0), 1 - x),
            height: min(max(0, height.isFinite ? height : 0), 1 - y)
        )
    }
}

/// One user-editable operation. IDs are intentionally strings so a saved
/// recipe can be reconciled with controls even when the operation is moved.
public struct EditOperation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var kind: EditOperationKind
    public var value: Double
    public var cropRect: EditCropRect?
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        kind: EditOperationKind,
        value: Double = 0,
        cropRect: EditCropRect? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.value = value.isFinite ? value : 0
        self.cropRect = cropRect?.clamped
        self.isEnabled = isEnabled
    }

    public static func stable(
        _ kind: EditOperationKind,
        value: Double = 0,
        cropRect: EditCropRect? = nil,
        isEnabled: Bool = true
    ) -> EditOperation {
        EditOperation(
            id: kind.rawValue,
            kind: kind,
            value: value,
            cropRect: cropRect,
            isEnabled: isEnabled
        )
    }
}
