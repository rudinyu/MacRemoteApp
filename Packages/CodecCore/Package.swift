// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodecCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodecCore", targets: ["CodecCore"])
    ],
    targets: [
        .target(
            name: "CodecCore",
            path: "Sources/CodecCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CodecCoreTests",
            dependencies: ["CodecCore"],
            path: "Tests/CodecCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
