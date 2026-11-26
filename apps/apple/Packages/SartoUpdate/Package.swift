// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SartoUpdate",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "SartoUpdate",
            targets: ["SartoUpdate"]
        ),
    ],
    targets: [
        .target(
            name: "SartoUpdate",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "SartoUpdateTests",
            dependencies: ["SartoUpdate"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
