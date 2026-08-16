// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PenguinChatMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PenguinChatCore", targets: ["PenguinChatCore"]),
        .library(name: "PenguinChatSocketIO", targets: ["PenguinChatSocketIO"]),
        .executable(name: "PenguinChatMac", targets: ["PenguinChatMac"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/socketio/socket.io-client-swift",
            exact: "16.1.1"
        ),
    ],
    targets: [
        .target(name: "PenguinChatCore"),
        .target(
            name: "PenguinChatSocketIO",
            dependencies: [
                "PenguinChatCore",
                .product(name: "SocketIO", package: "socket.io-client-swift"),
            ]
        ),
        .executableTarget(
            name: "PenguinChatMac",
            dependencies: ["PenguinChatCore", "PenguinChatSocketIO"]
        ),
        .testTarget(
            name: "PenguinChatCoreTests",
            dependencies: ["PenguinChatCore"]
        ),
    ]
)
