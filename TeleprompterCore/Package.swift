// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TeleprompterCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "TeleprompterCore",
            targets: ["TeleprompterCore"]
        )
    ],
    targets: [
        .target(
            name: "TeleprompterCore",
            path: "Sources/TeleprompterCore"
        ),
        .testTarget(
            name: "TeleprompterCoreTests",
            dependencies: ["TeleprompterCore"],
            path: "Tests/TeleprompterCoreTests"
        )
    ]
)
