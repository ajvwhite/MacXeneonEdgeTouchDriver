// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacXeneonEdgeTouchDriver",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MacXeneonEdgeTouchDriverCore", targets: ["MacXeneonEdgeTouchDriverCore"]),
        .executable(name: "MacXeneonEdgeTouchDriver", targets: ["MacXeneonEdgeTouchDriver"]),
        .executable(name: "DisplayInfo", targets: ["DisplayInfo"]),
        .executable(name: "HIDDump", targets: ["HIDDump"])
    ],
    targets: [
        .target(name: "MacXeneonEdgeTouchDriverCore"),
        .executableTarget(
            name: "MacXeneonEdgeTouchDriver",
            dependencies: ["MacXeneonEdgeTouchDriverCore"]
        ),
        .executableTarget(name: "DisplayInfo"),
        .executableTarget(name: "HIDDump"),
        .testTarget(
            name: "MacXeneonEdgeTouchDriverCoreTests",
            dependencies: ["MacXeneonEdgeTouchDriverCore"]
        )
    ]
)
