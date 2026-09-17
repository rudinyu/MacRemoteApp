// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SecurityCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SecurityCore", targets: ["SecurityCore"])
    ],
    targets: [
        .target(
            name: "SecurityCore",
            path: "Sources/SecurityCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SecurityCoreTests",
            dependencies: ["SecurityCore"],
            path: "Tests/SecurityCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
