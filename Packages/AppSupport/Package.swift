// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AppSupport",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AppSupport", targets: ["AppSupport"])
    ],
    targets: [
        .target(
            name: "AppSupport",
            path: "Sources/AppSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AppSupportTests",
            dependencies: ["AppSupport"],
            path: "Tests/AppSupportTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
