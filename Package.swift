// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Vibenotch",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "vendor/DynamicNotchKit")
    ],
    targets: [
        .executableTarget(
            name: "Vibenotch",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit")
            ],
            path: "Sources/Vibenotch",
            exclude: ["Info.plist"],
            resources: [.process("Resources")],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Vibenotch/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "VibenotchTests",
            dependencies: ["Vibenotch"],
            path: "Tests/VibenotchTests"
        )
    ]
)
