// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PrismDesign",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "PrismDesign",
            targets: ["PrismDesign"]
        ),
    ],
    targets: [
        .target(
            name: "PrismDesign",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "PrismDesignTests",
            dependencies: ["PrismDesign"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
