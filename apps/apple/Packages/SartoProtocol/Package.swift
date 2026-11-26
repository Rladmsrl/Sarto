// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SartoProtocol",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "SartoProtocol",
            targets: ["SartoProtocol"]
        ),
    ],
    targets: [
        .target(
            name: "SartoProtocol",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "SartoProtocolTests",
            dependencies: ["SartoProtocol"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
