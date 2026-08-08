// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NotchHUD",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "vendor/DynamicNotchKit")
    ],
    targets: [
        .executableTarget(
            name: "NotchHUD",
            dependencies: [
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit")
            ],
            path: "Sources/NotchHUD",
            exclude: ["Info.plist"],
            resources: [.process("Resources")],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/NotchHUD/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "NotchHUDTests",
            dependencies: ["NotchHUD"],
            path: "Tests/NotchHUDTests"
        )
    ]
)
