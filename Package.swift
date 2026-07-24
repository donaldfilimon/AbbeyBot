// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AbbeyBot",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "AbbeyCore", targets: ["AbbeyCore"]),
        .executable(name: "AbbeyBot", targets: ["AbbeyBotApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/DiscordBM/DiscordBM", from: "1.16.0")
    ],
    targets: [
        .target(
            name: "AbbeyCore",
            dependencies: [
                .product(name: "DiscordBM", package: "DiscordBM")
            ],
            path: "Sources/AbbeyCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "AbbeyBotApp",
            dependencies: ["AbbeyCore"],
            path: "Sources/AbbeyBotApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AbbeyCoreTests",
            dependencies: ["AbbeyCore"],
            path: "Tests/AbbeyCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
