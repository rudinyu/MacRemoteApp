// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TransportCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TransportCore", targets: ["TransportCore"])
    ],
    dependencies: [
        .package(path: "../RemoteProtocol"),
        .package(path: "../SecurityCore")
    ],
    targets: [
        .target(
            name: "TransportCore",
            dependencies: [
                .product(name: "RemoteProtocol", package: "RemoteProtocol"),
                .product(name: "SecurityCore", package: "SecurityCore")
            ],
            path: "Sources/TransportCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TransportCoreTests",
            dependencies: ["TransportCore", "RemoteProtocol", "SecurityCore"],
            path: "Tests/TransportCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
