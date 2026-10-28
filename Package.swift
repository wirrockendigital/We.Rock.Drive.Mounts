// swift-tools-version: 6.2

import PackageDescription

// The package keeps every executable surface on one shared domain core.
let package = Package(
    name: "WeRockDriveMounts",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WRDMCore", targets: ["WRDMCore"]),
        .executable(name: "WeRockDriveMounts", targets: ["WRDMApp"]),
        .executable(name: "wrdm-agent", targets: ["WRDMAgent"]),
        .executable(name: "wrdm", targets: ["WRDMCLI"]),
        .executable(name: "wrdm-mcp", targets: ["WRDMMCP"]),
    ],
    targets: [
        .target(name: "WRDMCore"),
        .executableTarget(name: "WRDMApp", dependencies: ["WRDMCore", "Sparkle"]),
        .executableTarget(name: "WRDMAgent", dependencies: ["WRDMCore"]),
        .executableTarget(name: "WRDMCLI", dependencies: ["WRDMCore"]),
        .executableTarget(name: "WRDMMCP", dependencies: ["WRDMCore"]),
        .testTarget(name: "WRDMAppTests", dependencies: ["WRDMApp", "WRDMCore"]),
        .testTarget(name: "WRDMCoreTests", dependencies: ["WRDMCore"], resources: [.copy("Fixtures")]),
        .binaryTarget(name: "Sparkle", path: "ThirdParty/Sparkle.xcframework"),
    ]
)
