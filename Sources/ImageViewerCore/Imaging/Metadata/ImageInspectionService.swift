import CoreGraphics
import Foundation

public struct ImageHistogram: Equatable, Sendable {
    public let red: [Int]
    public let green: [Int]
    public let blue: [Int]
    public let luminance: [Int]
    public let totalPixels: Int

    public init(
        red: [Int],
        green: [Int],
        blue: [Int],
        luminance: [Int],
        totalPixels: Int
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance
        self.totalPixels = totalPixels
    }

    public var binCount: Int { red.count }

    public var maximumBinCount: Int {
        max(
            red.max() ?? 0,
            green.max() ?? 0,
            blue.max() ?? 0,
            luminance.max() ?? 0
        )
    }
}

public struct PixelSample: Equatable, Sendable {
    public let normalizedPoint: CGPoint
    public let red: Int
    public let green: Int
    public let blue: Int
    public let alpha: Int

    public init(
        normalizedPoint: CGPoint,
        red: Int,
        green: Int,
        blue: Int,
        alpha: Int
    ) {
        self.normalizedPoint = normalizedPoint
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var hexadecimal: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    public var rgbaLabel: String {
        "R \(red)  G \(green)  B \(blue)  A \(alpha)"
    }
}

public enum ImageHistogramService {
    public static func compute(
        image: CGImage,
        binCount: Int = 64
    ) -> ImageHistogram {
        let count = max(2, binCount)
        var red = Array(repeating: 0, count: count)
        var green = Array(repeating: 0, count: count)
        var blue = Array(repeating: 0, count: count)
        var luminance = Array(repeating: 0, count: count)
        let totalPixels = max(0, image.width * image.height)

        guard totalPixels > 0,
              let providerData = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(providerData) else {
            return ImageHistogram(
                red: red,
                green: green,
                blue: blue,
                luminance: luminance,
                totalPixels: 0
            )
        }

        let bitsPerComponent = max(1, image.bitsPerComponent)
        let bytesPerComponent = max(1, (bitsPerComponent + 7) / 8)
        let componentsPerPixel = max(
            1,
            image.bitsPerPixel / max(1, bitsPerComponent)
        )
        let bytesPerPixel = max(bytesPerComponent, componentsPerPixel * bytesPerComponent)

        func component(_ offset: Int) -> Int {
            guard offset >= 0,
                  offset < image.bytesPerRow * image.height else {
                return 0
            }
            if bytesPerComponent == 1 {
                return Int(bytes[offset])
            }
            let high = Int(bytes[offset])
            let low = offset + 1 < image.bytesPerRow * image.height ? Int(bytes[offset + 1]) : 0
            return min(255, (high << 8 | low) >> 8)
        }

        for y in 0..<image.height {
            let rowOffset = y * image.bytesPerRow
            for x in 0..<image.width {
                let offset = rowOffset + x * bytesPerPixel
                let first = component(offset)
                let second = componentsPerPixel > 1 ? component(offset + bytesPerComponent) : first
                let third = componentsPerPixel > 2 ? component(offset + 2 * bytesPerComponent) : first
                let luminanceValue = min(
                    255,
                    max(0, Int((0.2126 * Double(first)) + (0.7152 * Double(second)) + (0.0722 * Double(third))))
                )
                red[min(count - 1, first * count / 256)] += 1
                green[min(count - 1, second * count / 256)] += 1
                blue[min(count - 1, third * count / 256)] += 1
                luminance[min(count - 1, luminanceValue * count / 256)] += 1
            }
        }

        return ImageHistogram(
            red: red,
            green: green,
            blue: blue,
            luminance: luminance,
            totalPixels: totalPixels
        )
    }
}

public enum PixelSampler {
    public static func sample(
        image: CGImage,
        at normalizedPoint: CGPoint
    ) -> PixelSample? {
        guard image.width > 0, image.height > 0,
              let providerData = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(providerData) else {
            return nil
        }

        let normalized = CGPoint(
            x: min(1, max(0, normalizedPoint.x)),
            y: min(1, max(0, normalizedPoint.y))
        )
        let x = min(image.width - 1, max(0, Int(normalized.x * CGFloat(image.width))))
        let yFromTop = min(image.height - 1, max(0, Int(normalized.y * CGFloat(image.height))))
        let y = image.height - 1 - yFromTop
        let bitsPerComponent = max(1, image.bitsPerComponent)
        let bytesPerComponent = max(1, (bitsPerComponent + 7) / 8)
        let components = max(1, image.bitsPerPixel / max(1, bitsPerComponent))
        let bytesPerPixel = max(bytesPerComponent, components * bytesPerComponent)
        let offset = y * image.bytesPerRow + x * bytesPerPixel
        guard offset >= 0,
              offset < image.bytesPerRow * image.height else {
            return nil
        }

        func component(_ componentIndex: Int) -> Int {
            let index = offset + componentIndex * bytesPerComponent
            guard index < image.bytesPerRow * image.height else { return 0 }
            return min(255, Int(bytes[index]))
        }
        let red = component(0)
        let green = components > 1 ? component(1) : red
        let blue = components > 2 ? component(2) : red
        let hasAlpha = image.alphaInfo != .none
            && image.alphaInfo != .noneSkipLast
            && image.alphaInfo != .noneSkipFirst
        let alpha = hasAlpha && components > 3 ? component(3) : 255

        return PixelSample(
            normalizedPoint: normalized,
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
}
