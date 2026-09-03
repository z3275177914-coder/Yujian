import CoreGraphics
import Foundation
import ImageIO

/// A source image representation used by the progressive canvas renderer.
///
/// `pixelSize` describes the logical source image, while the canvas may use a
/// much smaller proxy image for its first visible frame. Keeping these two
/// sizes separate lets every representation share one transform without
/// changing viewport math.
public struct ImageRepresentation: Equatable, Sendable {
    public let sourceURL: URL?
    public let pixelSize: ImageTilePixelSize
    public let proxyMaxPixelSize: Int
    public let tileDescriptor: ImageTileDescriptor

    public init(
        sourceURL: URL? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        proxyMaxPixelSize: Int = ImageTilePixelSize.interactiveMaxPixelSize,
        tileSize: Int = 512
    ) {
        let safeWidth = max(0, pixelWidth)
        let safeHeight = max(0, pixelHeight)
        let safeProxySize = max(1, proxyMaxPixelSize)
        self.sourceURL = sourceURL
        self.pixelSize = ImageTilePixelSize(width: safeWidth, height: safeHeight)
        self.proxyMaxPixelSize = safeProxySize
        self.tileDescriptor = ImageTileDescriptor(
            pixelWidth: safeWidth,
            pixelHeight: safeHeight,
            tileSize: tileSize,
            proxyMaxPixelSize: safeProxySize
        )
    }

    public var isLargeImage: Bool {
        pixelSize.isLargeImage
    }
}

public struct ImageTilePixelSize: Equatable, Sendable {
    /// Maximum longest side used by the interactive bitmap. Keeping this near
    /// the largest common Retina canvas dimension makes panning a texture
    /// operation instead of repeatedly touching a camera-sized bitmap.
    public static let interactiveMaxPixelSize = 2_048
    public static let detailMaxPixelSize = 4_096
    public static let interactivePixelBudget: Int64 = 16_000_000
    public static let detailPixelBudget: Int64 = 12_000_000

    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public var pixelCount: Int64 {
        Int64(width) * Int64(height)
    }

    public var isValid: Bool {
        width > 0 && height > 0
    }

    /// Keep the interactive texture bounded. Images above this budget start
    /// with a proxy layer and promote to source-backed tiles after settling.
    public var isLargeImage: Bool {
        max(width, height) > Self.interactiveMaxPixelSize
            || pixelCount > Self.interactivePixelBudget
    }

    /// Returns a bounded detail decode size. A large source is never expanded
    /// into an unbounded full-resolution bitmap just to feed the tile cache.
    public static func detailDecodeMaxPixelSize(
        for sourceSize: ImageTilePixelSize
    ) -> Int {
        guard sourceSize.isValid else {
            return 1
        }

        let sourcePixels = max(1, sourceSize.pixelCount)
        let budgetScale = min(
            1,
            sqrt(Double(detailPixelBudget) / Double(sourcePixels))
        )
        let budgetLongestSide = Double(max(sourceSize.width, sourceSize.height)) * budgetScale
        return max(
            1,
            min(detailMaxPixelSize, Int(budgetLongestSide.rounded(.down)))
        )
    }
}

public struct ImageTileGridSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(0, columns)
        self.rows = max(0, rows)
    }
}

/// Identifies one tile. Level zero is full resolution; larger levels are
/// progressively downsampled by powers of two.
public struct ImageTileCoordinate: Hashable, Sendable {
    public let level: Int
    public let column: Int
    public let row: Int

    public init(level: Int, column: Int, row: Int) {
        self.level = max(0, level)
        self.column = max(0, column)
        self.row = max(0, row)
    }
}

public struct ImageTileProviderStats: Equatable, Sendable {
    public let cachedTileCount: Int
    public let currentCost: Int
    public let byteBudget: Int
    public let isHighResolutionEnabled: Bool
    public let isHighResolutionRequestInFlight: Bool

    public init(
        cachedTileCount: Int,
        currentCost: Int,
        byteBudget: Int,
        isHighResolutionEnabled: Bool,
        isHighResolutionRequestInFlight: Bool
    ) {
        self.cachedTileCount = cachedTileCount
        self.currentCost = currentCost
        self.byteBudget = byteBudget
        self.isHighResolutionEnabled = isHighResolutionEnabled
        self.isHighResolutionRequestInFlight = isHighResolutionRequestInFlight
    }
}

public struct ImageTileDescriptor: Equatable, Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let tileSize: Int
    public let maximumLevel: Int
    public let proxyMaxPixelSize: Int

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        tileSize: Int = 512,
        proxyMaxPixelSize: Int = ImageTilePixelSize.interactiveMaxPixelSize
    ) {
        self.pixelWidth = max(0, pixelWidth)
        self.pixelHeight = max(0, pixelHeight)
        self.tileSize = max(1, tileSize)
        self.proxyMaxPixelSize = max(1, proxyMaxPixelSize)

        var level = 0
        var longestSide = max(self.pixelWidth, self.pixelHeight)
        while longestSide > self.proxyMaxPixelSize {
            longestSide = (longestSide + 1) / 2
            level += 1
        }
        self.maximumLevel = level
    }

    public var pixelSize: ImageTilePixelSize {
        ImageTilePixelSize(width: pixelWidth, height: pixelHeight)
    }

    public var isValid: Bool {
        pixelWidth > 0 && pixelHeight > 0
    }

    public func clampedLevel(_ level: Int) -> Int {
        min(maximumLevel, max(0, level))
    }

    public func downsampledPixelSize(at level: Int) -> ImageTilePixelSize {
        let safeLevel = clampedLevel(level)
        let divisor = pow2(safeLevel)
        return ImageTilePixelSize(
            width: max(1, (pixelWidth + divisor - 1) / divisor),
            height: max(1, (pixelHeight + divisor - 1) / divisor)
        )
    }

    public func tileGridSize(at level: Int) -> ImageTileGridSize {
        guard isValid else {
            return ImageTileGridSize(columns: 0, rows: 0)
        }

        let safeLevel = clampedLevel(level)
        let coverage = Int(tileCoverage(at: safeLevel))
        return ImageTileGridSize(
            columns: (pixelWidth + coverage - 1) / coverage,
            rows: (pixelHeight + coverage - 1) / coverage
        )
    }

    /// Returns a tile's source-pixel rectangle. Rectangles are clipped to the
    /// source image, so the final row and column never request padding pixels.
    public func pixelRect(for coordinate: ImageTileCoordinate) -> CGRect {
        guard isValid else {
            return .zero
        }

        let level = clampedLevel(coordinate.level)
        let coverage = tileCoverage(at: level)
        let grid = tileGridSize(at: level)
        let column = min(max(0, coordinate.column), max(0, grid.columns - 1))
        let row = min(max(0, coordinate.row), max(0, grid.rows - 1))
        let rect = CGRect(
            x: CGFloat(column) * coverage,
            y: CGFloat(row) * coverage,
            width: coverage,
            height: coverage
        )
        return rect.intersection(CGRect(
            x: 0,
            y: 0,
            width: CGFloat(pixelWidth),
            height: CGFloat(pixelHeight)
        ))
    }

    /// Finds all tiles intersecting a full-resolution pixel rectangle.
    public func tiles(
        intersecting pixelRect: CGRect,
        at level: Int
    ) -> [ImageTileCoordinate] {
        guard isValid else {
            return []
        }

        let safeLevel = clampedLevel(level)
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(pixelWidth),
            height: CGFloat(pixelHeight)
        )
        let clipped = pixelRect.intersection(imageBounds)
        guard clipped.width > 0, clipped.height > 0 else {
            return []
        }

        let coverage = tileCoverage(at: safeLevel)
        let grid = tileGridSize(at: safeLevel)
        let minimumColumn = max(0, min(
            grid.columns - 1,
            Int(floor(clipped.minX / coverage))
        ))
        let minimumRow = max(0, min(
            grid.rows - 1,
            Int(floor(clipped.minY / coverage))
        ))
        let maximumColumn = max(0, min(
            grid.columns - 1,
            Int(ceil(clipped.maxX / coverage)) - 1
        ))
        let maximumRow = max(0, min(
            grid.rows - 1,
            Int(ceil(clipped.maxY / coverage)) - 1
        ))

        guard minimumColumn <= maximumColumn, minimumRow <= maximumRow else {
            return []
        }

        var result: [ImageTileCoordinate] = []
        result.reserveCapacity(
            (maximumColumn - minimumColumn + 1)
                * (maximumRow - minimumRow + 1)
        )
        for row in minimumRow...maximumRow {
            for column in minimumColumn...maximumColumn {
                result.append(ImageTileCoordinate(
                    level: safeLevel,
                    column: column,
                    row: row
                ))
            }
        }
        return result
    }

    /// Selects a level that supplies roughly one source pixel per display
    /// point. A zoomed-in view always resolves to level zero.
    public func level(forEffectiveScale effectiveScale: CGFloat) -> Int {
        guard effectiveScale.isFinite, effectiveScale > 0 else {
            return maximumLevel
        }
        guard effectiveScale < 1 else {
            return 0
        }
        return clampedLevel(Int(floor(-log2(Double(effectiveScale)))))
    }

    public static func rotatedPixelSize(
        width: Int,
        height: Int,
        degrees: Double
    ) -> ImageTilePixelSize {
        let safeWidth = max(0, width)
        let safeHeight = max(0, height)
        guard degrees.isFinite else {
            return ImageTilePixelSize(width: safeWidth, height: safeHeight)
        }

        let radians = degrees * .pi / 180
        let rotatedWidth = abs(cos(radians)) * Double(safeWidth)
            + abs(sin(radians)) * Double(safeHeight)
        let rotatedHeight = abs(sin(radians)) * Double(safeWidth)
            + abs(cos(radians)) * Double(safeHeight)
        return ImageTilePixelSize(
            width: max(0, Int(ceil(rotatedWidth - 0.000_001))),
            height: max(0, Int(ceil(rotatedHeight - 0.000_001)))
        )
    }

    private func tileCoverage(at level: Int) -> CGFloat {
        CGFloat(tileSize) * CGFloat(pow2(clampedLevel(level)))
    }

    private func pow2(_ level: Int) -> Int {
        if level >= Int.bitWidth - 2 {
            return Int.max / max(tileSize, 1)
        }
        return 1 << max(0, level)
    }
}

/// Small, synchronous revision gate shared by asynchronous tile requests.
/// Work that finishes after cancellation may still consume decoder time, but
/// it cannot publish stale tiles into a newer canvas representation.
public final class ImageTileRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var revisionValue: UInt64 = 0

    public init() {}

    @discardableResult
    public func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        revisionValue &+= 1
        return revisionValue
    }

    public func cancel() {
        lock.lock()
        revisionValue &+= 1
        lock.unlock()
    }

    public func isCurrent(_ revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revision == revisionValue
    }
}

/// Thread-safe source detail provider.
///
/// The provider intentionally starts with a proxy crop. If a source URL is
/// available, a bounded detail representation is decoded lazily only after
/// the canvas enables high-resolution rendering. ImageIO does not expose a
/// portable region-decode API for every format supported by the app, so this
/// backend downsamples once and can crop/cache source-coordinate tiles. The
/// proxy remains a safe fallback for unsupported or cancelled requests.
public final class ImageTileProvider: @unchecked Sendable {
    public typealias DetailReadyHandler = () -> Void

    private struct CachedTile {
        let image: CGImage
        let cost: Int
        var lastAccess: UInt64
    }

    public let descriptor: ImageTileDescriptor

    private let proxyImage: CGImage
    private let sourceURL: URL?
    private let byteBudget: Int
    private let onDetailReady: DetailReadyHandler?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let requestGate = ImageTileRequestGate()
    private var detailImage: CGImage?
    private var highResolutionEnabled = false
    private var detailDecodeRequested = false
    private var highResolutionPromotionPending = false
    private var highResolutionPromotionToken: UInt64 = 0
    private var cachedTiles: [ImageTileCoordinate: CachedTile] = [:]
    private var accessCounter: UInt64 = 0
    private var totalCost = 0

    public init(
        descriptor: ImageTileDescriptor,
        proxyImage: CGImage,
        sourceURL: URL? = nil,
        byteBudget: Int = 64 * 1024 * 1024,
        onDetailReady: DetailReadyHandler? = nil
    ) {
        self.descriptor = descriptor
        self.proxyImage = proxyImage
        self.sourceURL = sourceURL
        self.byteBudget = max(1, byteBudget)
        self.onDetailReady = onDetailReady
        self.queue = DispatchQueue(
            label: "com.imageviewer.tile-provider",
            // Detail promotion is a settled-quality task. It must not
            // outrank pointer events or compete with Core Animation while a
            // user starts another gesture.
            qos: .utility
        )
        self.detailImage = nil
        if proxyImage.width == descriptor.pixelWidth,
           proxyImage.height == descriptor.pixelHeight {
            self.detailImage = proxyImage
        }
    }

    /// Returns the bounded detail representation when its background decode
    /// has completed. The viewer uses this as one stable texture for zooming
    /// and panning, while the tile API remains available for a future true
    /// region decoder.
    public func detailImageIfAvailable() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return detailImage
    }

    public func setHighResolutionEnabled(_ enabled: Bool) {
        lock.lock()
        if !enabled {
            highResolutionPromotionPending = false
            highResolutionPromotionToken &+= 1
            highResolutionEnabled = false
            lock.unlock()
            requestGate.cancel()
            return
        }

        guard !highResolutionEnabled,
              !highResolutionPromotionPending,
              detailImage == nil,
              sourceURL != nil else {
            lock.unlock()
            return
        }
        if detailDecodeRequested {
            // A decode invalidated by a short gesture may still be finishing.
            // Mark the new settled state as desired so its stale completion
            // immediately schedules one replacement instead of losing the
            // high-resolution request altogether.
            highResolutionEnabled = true
            lock.unlock()
            return
        }
        highResolutionPromotionPending = true
        highResolutionPromotionToken &+= 1
        let promotionToken = highResolutionPromotionToken
        lock.unlock()

        // Do not begin a detail decode on the first settled frame. Users
        // often start the next pan immediately after zooming; giving the
        // interaction a quiet window keeps that decode from contending with
        // pointer delivery and Core Animation.
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            self?.promoteHighResolutionIfCurrent(promotionToken)
        }
    }

    public func image(for coordinate: ImageTileCoordinate) -> CGImage? {
        guard isValid(coordinate) else {
            return nil
        }

        lock.lock()
        if var cached = cachedTiles[coordinate] {
            accessCounter &+= 1
            cached.lastAccess = accessCounter
            cachedTiles[coordinate] = cached
            lock.unlock()
            return cached.image
        }
        let resolvedDetailImage = detailImage
        let shouldRequest = highResolutionEnabled
            && resolvedDetailImage == nil
            && sourceURL != nil
        lock.unlock()

        if shouldRequest {
            requestDetailImageIfNeeded()
        }

        let image: CGImage?
        if let resolvedDetailImage {
            image = crop(
                resolvedDetailImage,
                to: descriptor.pixelRect(for: coordinate),
                relativeTo: descriptor.pixelSize
            )
        } else {
            image = proxyTile(for: coordinate)
        }

        if let image, resolvedDetailImage != nil {
            cache(image, for: coordinate)
        }
        return image
    }

    public func stats() -> ImageTileProviderStats {
        lock.lock()
        defer { lock.unlock() }
        return ImageTileProviderStats(
            cachedTileCount: cachedTiles.count,
            currentCost: totalCost,
            byteBudget: byteBudget,
            isHighResolutionEnabled: highResolutionEnabled,
            isHighResolutionRequestInFlight: detailDecodeRequested
        )
    }

    public func cancelOutstandingRequests() {
        requestGate.cancel()
        lock.lock()
        // ImageIO decoding is synchronous on the provider queue and cannot be
        // interrupted safely. Keep the in-flight marker until that decode
        // returns so a new settle event cannot start a second detail decode.
        highResolutionPromotionPending = false
        highResolutionPromotionToken &+= 1
        highResolutionEnabled = false
        lock.unlock()
    }

    private func requestDetailImageIfNeeded() {
        guard let sourceURL else {
            return
        }

        lock.lock()
        guard highResolutionEnabled,
              !detailDecodeRequested,
              detailImage == nil else {
            lock.unlock()
            return
        }
        detailDecodeRequested = true
        let revision = requestGate.begin()
        let sourceSize = descriptor.pixelSize
        lock.unlock()

        queue.async { [weak self] in
            guard let self else {
                return
            }
            let decoded = Self.decodeDetailImage(
                sourceURL,
                sourceSize: sourceSize
            )

            self.lock.lock()
            let isCurrent = self.requestGate.isCurrent(revision)
            self.detailDecodeRequested = false
            if isCurrent, let decoded {
                self.detailImage = decoded
                self.cachedTiles.removeAll(keepingCapacity: true)
                self.totalCost = 0
            }
            let shouldRetry = !isCurrent
                && self.highResolutionEnabled
                && self.detailImage == nil
                && self.sourceURL != nil
            self.lock.unlock()

            guard isCurrent, decoded != nil else {
                if shouldRetry {
                    self.requestDetailImageIfNeeded()
                }
                return
            }
            self.onDetailReady?()
        }
    }

    private func promoteHighResolutionIfCurrent(_ token: UInt64) {
        lock.lock()
        guard token == highResolutionPromotionToken,
              highResolutionPromotionPending,
              detailImage == nil,
              !detailDecodeRequested,
              sourceURL != nil else {
            lock.unlock()
            return
        }
        highResolutionPromotionPending = false
        highResolutionEnabled = true
        lock.unlock()
        requestDetailImageIfNeeded()
    }

    private func proxyTile(for coordinate: ImageTileCoordinate) -> CGImage? {
        let sourceRect = descriptor.pixelRect(for: coordinate)
        guard sourceRect.width > 0, sourceRect.height > 0,
              descriptor.pixelWidth > 0, descriptor.pixelHeight > 0 else {
            return nil
        }

        return crop(
            proxyImage,
            to: sourceRect,
            relativeTo: descriptor.pixelSize
        )
    }

    private func isValid(_ coordinate: ImageTileCoordinate) -> Bool {
        guard descriptor.isValid,
              coordinate.level >= 0,
              coordinate.level <= descriptor.maximumLevel else {
            return false
        }
        let grid = descriptor.tileGridSize(at: coordinate.level)
        return coordinate.column < grid.columns && coordinate.row < grid.rows
    }

    private func cache(_ image: CGImage, for coordinate: ImageTileCoordinate) {
        let cost = max(1, image.width * image.height * 4)
        guard cost <= byteBudget else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        if let previous = cachedTiles.removeValue(forKey: coordinate) {
            totalCost -= previous.cost
        }
        while totalCost + cost > byteBudget,
              let key = cachedTiles.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            if let removed = cachedTiles.removeValue(forKey: key) {
                totalCost -= removed.cost
            }
        }
        accessCounter &+= 1
        cachedTiles[coordinate] = CachedTile(
            image: image,
            cost: cost,
            lastAccess: accessCounter
        )
        totalCost += cost
    }

    private func crop(
        _ image: CGImage,
        to rect: CGRect,
        relativeTo sourceSize: ImageTilePixelSize
    ) -> CGImage? {
        guard sourceSize.isValid,
              image.width > 0,
              image.height > 0 else {
            return nil
        }
        let scaleX = CGFloat(image.width) / CGFloat(sourceSize.width)
        let scaleY = CGFloat(image.height) / CGFloat(sourceSize.height)
        guard scaleX.isFinite, scaleX > 0, scaleY.isFinite, scaleY > 0 else {
            return nil
        }

        let imageRect = CGRect(
            x: rect.minX * scaleX,
            y: rect.minY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
        let minX = max(0, min(image.width - 1, Int(floor(imageRect.minX))))
        let minY = max(0, min(image.height - 1, Int(floor(imageRect.minY))))
        let maxX = max(minX + 1, min(image.width, Int(ceil(imageRect.maxX))))
        let maxY = max(minY + 1, min(image.height, Int(ceil(imageRect.maxY))))
        guard maxX > minX, maxY > minY else {
            return nil
        }
        return image.cropping(to: CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ))
    }

    private static func decodeDetailImage(
        _ url: URL,
        sourceSize: ImageTilePixelSize
    ) -> CGImage? {
        ImageDecoder.decodeCGImage(
            url: url,
            maxPixelSize: ImageTilePixelSize.detailDecodeMaxPixelSize(
                for: sourceSize
            )
        )
    }
}
