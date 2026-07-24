// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AbbeyBot",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .library(name: "AbbeyCore", targets: ["AbbeyCore"]),
        .executable(name: "AbbeyBot", targets: ["AbbeyBotApp"]),
        .executable(name: "AbbeyServer", targets: ["AbbeyServer"]),
        .executable(name: "abbey", targets: ["AbbeyCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/DiscordBM/DiscordBM", from: "1.16.0"),
        .package(url: "https://github.com/vapor/vapor", from: "4.115.0"),
        .package(url: "https://github.com/vapor/fluent", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver", from: "2.9.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver", from: "4.6.0"),
        .package(url: "https://github.com/vapor/leaf", from: "4.4.0")
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
        .target(
            name: "AbbeyServerKit",
            dependencies: [
                "AbbeyCore",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "DiscordBM", package: "DiscordBM")
            ],
            path: "Sources/AbbeyServerKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "AbbeyServer",
            dependencies: [
                "AbbeyCore",
                "AbbeyServerKit",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "Leaf", package: "leaf"),
                .product(name: "DiscordBM", package: "DiscordBM")
            ],
            path: "Sources/AbbeyServer",
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "AbbeyCLI",
            dependencies: [
                "AbbeyCore",
                "AbbeyServerKit",
                .product(name: "Vapor", package: "vapor")
            ],
            path: "Sources/AbbeyCLI",
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
        ),
        .testTarget(
            name: "AbbeyCLITests",
            dependencies: ["AbbeyCLI"],
            path: "Tests/AbbeyCLITests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
