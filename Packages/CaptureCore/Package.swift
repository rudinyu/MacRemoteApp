// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CaptureCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CaptureCore", targets: ["CaptureCore"])
    ],
    targets: [
        .target(
            name: "CaptureCore",
            path: "Sources/CaptureCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CaptureCoreTests",
            dependencies: ["CaptureCore"],
            path: "Tests/CaptureCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
