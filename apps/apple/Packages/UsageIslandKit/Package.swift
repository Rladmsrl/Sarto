// swift-tools-version:5.10
import PackageDescription

// The Mac app's usage views, whose figures the Sarto daemon computes: UsageCore picks which agent
// the Dynamic Island follows, and MenuBarKit draws the status item, frosted panel, liquid tubes,
// segmented rings and count-up, from llm-usage-island.
let package = Package(
    name: "UsageIslandKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .library(name: "MenuBarKit", targets: ["MenuBarKit"]),
    ],
    targets: [
        .target(name: "UsageCore"),
        .target(
            name: "MenuBarKit",
            resources: [.copy("Fonts")]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"]
        ),
    ]
)
