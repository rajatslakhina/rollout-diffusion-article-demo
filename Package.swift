// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RolloutDiffusion",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RolloutDiffusion", targets: ["RolloutDiffusion"])
    ],
    targets: [
        .target(name: "RolloutDiffusion"),
        .testTarget(name: "RolloutDiffusionTests", dependencies: ["RolloutDiffusion"])
    ]
)
