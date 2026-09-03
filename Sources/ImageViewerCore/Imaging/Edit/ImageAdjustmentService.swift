import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public struct ImageAdjustments: Codable, Equatable, Sendable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var sharpness: Double
    public var exposure: Double
    public var highlights: Double
    public var shadows: Double
    public var temperature: Double
    public var tint: Double

    public init(
        brightness: Double = 0,
        contrast: Double = 1,
        saturation: Double = 1,
        sharpness: Double = 0,
        exposure: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        temperature: Double = 0,
        tint: Double = 0
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.sharpness = sharpness
        self.exposure = exposure
        self.highlights = highlights
        self.shadows = shadows
        self.temperature = temperature
        self.tint = tint
    }

    public static let `default` = ImageAdjustments()

    public var isDefault: Bool {
        self == .default
    }

    public var clamped: ImageAdjustments {
        ImageAdjustments(
            brightness: min(1, max(-1, brightness.isFinite ? brightness : 0)),
            contrast: min(2, max(0, contrast.isFinite ? contrast : 1)),
            saturation: min(2, max(0, saturation.isFinite ? saturation : 1)),
            sharpness: min(2, max(0, sharpness.isFinite ? sharpness : 0)),
            exposure: min(2, max(-2, exposure.isFinite ? exposure : 0)),
            highlights: min(1, max(-1, highlights.isFinite ? highlights : 0)),
            shadows: min(1, max(-1, shadows.isFinite ? shadows : 0)),
            temperature: min(1, max(-1, temperature.isFinite ? temperature : 0)),
            tint: min(1, max(-1, tint.isFinite ? tint : 0))
        )
    }
}

public enum ImageRenderQuality: String, Equatable, Sendable {
    case interactive
    case settled

    public var intermediateMaxPixelSize: Int? {
        switch self {
        case .interactive:
            return 1_280
        case .settled:
            return nil
        }
    }
}

/// A thread-safe latest-wins revision gate shared by render executors.
public final class LatestWinsRenderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var latestRevision: UInt64 = 0

    @discardableResult
    public func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        latestRevision &+= 1
        return latestRevision
    }

    public func isCurrent(_ revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revision == latestRevision
    }
}

/// Long-lived Core Image renderer. Requests are serialized so obsolete queued
/// adjustments are discarded before rendering, while an already-running Core
/// Image command is allowed to finish and its result is then dropped.
public final class ImageRenderService: @unchecked Sendable {
    public static let shared = ImageRenderService()

    private let renderQueue = DispatchQueue(
        label: "com.imageviewer.image-render",
        qos: .userInitiated
    )
    private let context: CIContext
    private let workingColorSpace: CGColorSpace
    private let gate = LatestWinsRenderGate()

    public let contextIdentifier: ObjectIdentifier
    public let workingColorSpaceName: String

    public init() {
        guard let workingColorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            preconditionFailure("sRGB color space is unavailable")
        }
        self.workingColorSpace = workingColorSpace
        self.context = CIContext(options: [
            .workingColorSpace: workingColorSpace,
            .outputColorSpace: workingColorSpace,
            .cacheIntermediates: true
        ])
        self.contextIdentifier = ObjectIdentifier(context)
        self.workingColorSpaceName = "sRGB"
    }

    public func renderLatest(
        to image: CGImage,
        adjustments: ImageAdjustments,
        quality: ImageRenderQuality = .settled
    ) -> CGImage? {
        let signpostID = PerformanceLog.begin("RenderAdjustment")
        defer {
            PerformanceLog.end("RenderAdjustment", signpostID: signpostID)
        }

        let adjustments = adjustments.clamped
        guard !adjustments.isDefault else {
            return image
        }

        let revision = gate.begin()
        return renderQueue.sync {
            guard gate.isCurrent(revision) else {
                return nil
            }

            let rendered = render(
                to: image,
                adjustments: adjustments,
                quality: quality
            )
            guard gate.isCurrent(revision) else {
                return nil
            }
            return rendered
        }
    }

    /// Renders an independent request without invalidating another caller's
    /// request. Export, histogram fixtures and batch work use this path;
    /// interactive callers can continue to use `renderLatest`.
    public func renderStable(
        to image: CGImage,
        adjustments: ImageAdjustments,
        quality: ImageRenderQuality = .settled
    ) -> CGImage? {
        let adjustments = adjustments.clamped
        guard !adjustments.isDefault else {
            return image
        }
        return renderQueue.sync {
            render(to: image, adjustments: adjustments, quality: quality)
        }
    }

    private func render(
        to image: CGImage,
        adjustments: ImageAdjustments,
        quality: ImageRenderQuality
    ) -> CGImage? {
        let sourceExtent = CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        )
        let intermediateScale = min(
            1,
            quality.intermediateMaxPixelSize.map { maximum in
                CGFloat(maximum) / max(CGFloat(image.width), CGFloat(image.height))
            } ?? 1
        )

        var output = CIImage(cgImage: image)
        if intermediateScale < 1 {
            output = output.transformed(
                by: CGAffineTransform(
                    scaleX: intermediateScale,
                    y: intermediateScale
                )
            )
        }

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = output
        colorControls.brightness = Float(adjustments.brightness)
        colorControls.contrast = Float(adjustments.contrast)
        colorControls.saturation = Float(adjustments.saturation)
        guard let colorOutput = colorControls.outputImage else {
            return nil
        }
        output = colorOutput

        if adjustments.exposure != 0 {
            let exposure = CIFilter(name: "CIExposureAdjust")
            exposure?.setValue(output, forKey: kCIInputImageKey)
            exposure?.setValue(Float(adjustments.exposure), forKey: "inputEV")
            if let exposureOutput = exposure?.outputImage {
                output = exposureOutput
            }
        }

        if adjustments.highlights != 0 || adjustments.shadows != 0 {
            let highlightShadow = CIFilter(name: "CIHighlightShadowAdjust")
            highlightShadow?.setValue(output, forKey: kCIInputImageKey)
            highlightShadow?.setValue(Float(1 - adjustments.highlights), forKey: "inputHighlightAmount")
            highlightShadow?.setValue(Float(1 + adjustments.shadows), forKey: "inputShadowAmount")
            if let highlightShadowOutput = highlightShadow?.outputImage {
                output = highlightShadowOutput
            }
        }

        if adjustments.temperature != 0 || adjustments.tint != 0 {
            let temperature = CIFilter(name: "CITemperatureAndTint")
            temperature?.setValue(output, forKey: kCIInputImageKey)
            temperature?.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temperature?.setValue(
                CIVector(
                    x: 6500 - adjustments.temperature * 2_500,
                    y: adjustments.tint * 100
                ),
                forKey: "inputTargetNeutral"
            )
            if let temperatureOutput = temperature?.outputImage {
                output = temperatureOutput
            }
        }

        if adjustments.sharpness > 0 {
            let unsharpMask = CIFilter.unsharpMask()
            unsharpMask.inputImage = output
            unsharpMask.radius = 2
            unsharpMask.intensity = Float(adjustments.sharpness)
            guard let sharpenedOutput = unsharpMask.outputImage else {
                return nil
            }
            output = sharpenedOutput
        }

        if intermediateScale < 1 {
            let inverseScale = 1 / intermediateScale
            output = output.transformed(
                by: CGAffineTransform(
                    scaleX: inverseScale,
                    y: inverseScale
                )
            )
        }

        return context.createCGImage(output, from: sourceExtent)
    }
}

public enum ImageAdjustmentService {
    public static func apply(
        to image: CGImage,
        adjustments: ImageAdjustments,
        quality: ImageRenderQuality = .settled
    ) -> CGImage? {
        ImageRenderService.shared.renderStable(
            to: image,
            adjustments: adjustments,
            quality: quality
        )
    }

    public static func crop(
        _ image: CGImage,
        to normalizedRect: EditCropRect
    ) -> CGImage? {
        let rect = normalizedRect.clamped
        guard rect.width > 0, rect.height > 0 else {
            return nil
        }

        // Recipes use a top-left normalized coordinate system. CGImage uses
        // a bottom-left coordinate system, so convert only at this boundary.
        let cropRect = CGRect(
            x: rect.x * Double(image.width),
            y: (1 - rect.y - rect.height) * Double(image.height),
            width: rect.width * Double(image.width),
            height: rect.height * Double(image.height)
        ).integral.intersection(CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        ))
        guard cropRect.width >= 1, cropRect.height >= 1 else {
            return nil
        }
        return image.cropping(to: cropRect)
    }
}

/// Applies the pixel-affecting part of a recipe in operation order. View-only
/// transforms (rotation and flip) remain in CanvasTransformState during
/// interaction and are applied by the export renderer when pixels are saved.
public enum ImageRecipeRenderer {
    public static func renderPreviewPixels(
        image: CGImage,
        recipe: EditRecipe,
        quality: ImageRenderQuality = .settled
    ) -> CGImage? {
        var output = image
        for operation in recipe.enabledOperations {
            switch operation.kind {
            case .brightness:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(brightness: operation.value),
                    quality: quality
                ) ?? output
            case .contrast:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(contrast: operation.value),
                    quality: quality
                ) ?? output
            case .saturation:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(saturation: operation.value),
                    quality: quality
                ) ?? output
            case .sharpness:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(sharpness: operation.value),
                    quality: quality
                ) ?? output
            case .exposure:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(exposure: operation.value),
                    quality: quality
                ) ?? output
            case .highlights:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(highlights: operation.value),
                    quality: quality
                ) ?? output
            case .shadows:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(shadows: operation.value),
                    quality: quality
                ) ?? output
            case .temperature:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(temperature: operation.value),
                    quality: quality
                ) ?? output
            case .tint:
                output = ImageAdjustmentService.apply(
                    to: output,
                    adjustments: ImageAdjustments(tint: operation.value),
                    quality: quality
                ) ?? output
            case .crop:
                if let cropRect = operation.cropRect,
                   let cropped = ImageAdjustmentService.crop(output, to: cropRect) {
                    output = cropped
                }
            case .rotate, .flipHorizontal, .straighten:
                break
            }
        }
        return output
    }
}
