// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ImageViewer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ImageViewer",
            targets: ["ImageViewer"]
        )
    ],
    targets: [
        .target(
            name: "ImageViewerCore"
        ),
        .executableTarget(
            name: "ImageViewer",
            dependencies: ["ImageViewerCore"]
        ),
        .testTarget(
            name: "ImageViewerCoreTests",
            dependencies: ["ImageViewerCore"]
        )
    ]
)
