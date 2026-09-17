// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacRemoteApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Host", targets: ["Host"]),
        .executable(name: "Viewer", targets: ["Viewer"])
    ],
    dependencies: [
        .package(path: "Packages/RemoteProtocol"),
        .package(path: "Packages/CaptureCore"),
        .package(path: "Packages/CodecCore"),
        .package(path: "Packages/TransportCore"),
        .package(path: "Packages/InputCore"),
        .package(path: "Packages/SecurityCore")
    ],
    targets: [
        .executableTarget(
            name: "Host",
            dependencies: [
                .product(name: "RemoteProtocol", package: "RemoteProtocol"),
                .product(name: "CaptureCore", package: "CaptureCore"),
                .product(name: "CodecCore", package: "CodecCore"),
                .product(name: "TransportCore", package: "TransportCore"),
                .product(name: "InputCore", package: "InputCore"),
                .product(name: "SecurityCore", package: "SecurityCore")
            ],
            path: "Apps/Host",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Viewer",
            dependencies: [
                .product(name: "RemoteProtocol", package: "RemoteProtocol"),
                .product(name: "CodecCore", package: "CodecCore"),
                .product(name: "TransportCore", package: "TransportCore"),
                .product(name: "InputCore", package: "InputCore"),
                .product(name: "SecurityCore", package: "SecurityCore")
            ],
            path: "Apps/Viewer",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MacRemoteAppSmokeTests",
            dependencies: [
                .product(name: "RemoteProtocol", package: "RemoteProtocol"),
                .product(name: "CaptureCore", package: "CaptureCore"),
                .product(name: "CodecCore", package: "CodecCore"),
                .product(name: "TransportCore", package: "TransportCore"),
                .product(name: "InputCore", package: "InputCore"),
                .product(name: "SecurityCore", package: "SecurityCore")
            ],
            path: "Tests/MacRemoteAppSmokeTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
