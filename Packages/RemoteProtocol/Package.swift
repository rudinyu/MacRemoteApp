// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RemoteProtocol",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RemoteProtocol", targets: ["RemoteProtocol"])
    ],
    targets: [
        .target(
            name: "RemoteProtocol",
            path: "Sources/RemoteProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RemoteProtocolTests",
            dependencies: ["RemoteProtocol"],
            path: "Tests/RemoteProtocolTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
