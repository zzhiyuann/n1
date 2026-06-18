// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "N1Stats",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "N1Stats", targets: ["N1Stats"])
    ],
    targets: [
        .target(name: "N1Stats"),
        .testTarget(name: "N1StatsTests", dependencies: ["N1Stats"]),
    ]
)
