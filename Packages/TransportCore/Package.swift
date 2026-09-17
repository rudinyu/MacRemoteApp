// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TransportCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TransportCore", targets: ["TransportCore"])
    ],
    targets: [
        .target(
            name: "TransportCore",
            path: "Sources/TransportCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TransportCoreTests",
            dependencies: ["TransportCore"],
            path: "Tests/TransportCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
