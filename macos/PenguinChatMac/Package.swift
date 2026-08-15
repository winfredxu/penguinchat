// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PenguinChatMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PenguinChatCore", targets: ["PenguinChatCore"]),
        .executable(name: "PenguinChatMac", targets: ["PenguinChatMac"]),
    ],
    targets: [
        .target(name: "PenguinChatCore"),
        .executableTarget(
            name: "PenguinChatMac",
            dependencies: ["PenguinChatCore"]
        ),
        .testTarget(
            name: "PenguinChatCoreTests",
            dependencies: ["PenguinChatCore"]
        ),
    ]
)
