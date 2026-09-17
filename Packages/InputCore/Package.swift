// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "InputCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "InputCore", targets: ["InputCore"])
    ],
    targets: [
        .target(
            name: "InputCore",
            path: "Sources/InputCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "InputCoreTests",
            dependencies: ["InputCore"],
            path: "Tests/InputCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
