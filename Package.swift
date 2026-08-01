// swift-tools-version: 6.4
import Foundation
import PackageDescription

/// When `ABBEY_PACKAGE_ROLE=server`, omit the SwiftUI/SwiftData desktop target so Linux
/// CI / Docker / swiftly can build the unified `AbbeyBot` executable without AppKit.
let serverOnlyPackage = ProcessInfo.processInfo.environment["ABBEY_PACKAGE_ROLE"] == "server"

var packageTargets: [Target] = [
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
    .target(
        name: "AbbeyServerKit",
        dependencies: [
            "AbbeyCore",
            .product(name: "Vapor", package: "vapor"),
            .product(name: "Fluent", package: "fluent"),
            .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
            .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            .product(name: "DiscordBM", package: "DiscordBM"),
            .product(name: "Crypto", package: "swift-crypto")
        ],
        path: "Sources/AbbeyServerKit",
        swiftSettings: [
            .swiftLanguageMode(.v6)
        ]
    ),
    .target(
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
    .target(
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
    ),
    .testTarget(
        name: "AbbeyServerKitTests",
        dependencies: [
            "AbbeyServerKit",
            .product(name: "Crypto", package: "swift-crypto")
        ],
        path: "Tests/AbbeyServerKitTests",
        swiftSettings: [
            .swiftLanguageMode(.v6)
        ]
    ),
    .testTarget(
        name: "AbbeyServerTests",
        dependencies: [
            "AbbeyServer",
            .product(name: "VaporTesting", package: "vapor")
        ],
        path: "Tests/AbbeyServerTests",
        swiftSettings: [
            .swiftLanguageMode(.v6)
        ]
    )
]

var entryDependencies: [Target.Dependency] = [
    "AbbeyCore",
    "AbbeyServer",
    "AbbeyCLI"
]

if !serverOnlyPackage {
    packageTargets.insert(
        .target(
            name: "AbbeyBotApp",
            dependencies: ["AbbeyCore"],
            path: "Sources/AbbeyBotApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        at: 1
    )
    packageTargets.append(
        .testTarget(
            name: "AbbeyBotAppTests",
            dependencies: ["AbbeyBotApp"],
            path: "Tests/AbbeyBotAppTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    )
    entryDependencies.insert("AbbeyBotApp", at: 0)
}

var entrySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]
if !serverOnlyPackage {
    // Prefer over `canImport(AbbeyBotApp)` — that can be true from a prior build
    // in the same scratch path even when the desktop target is omitted.
    entrySettings.append(.define("ABBEY_HAS_DESKTOP"))
}

packageTargets.append(
    .executableTarget(
        name: "AbbeyEntry",
        dependencies: entryDependencies,
        path: "Sources/AbbeyEntry",
        swiftSettings: entrySettings
    )
)

let package = Package(
    name: "AbbeyBot",
    platforms: [
        .macOS(.v27),
        .driverKit(.v27)
    ],
    products: [
        .library(name: "AbbeyCore", targets: ["AbbeyCore"]),
        .library(name: "AbbeyServerKit", targets: ["AbbeyServerKit"]),
        // Sole executable product → bare `swift run` works (defaults to desktop on macOS).
        // Roles: `swift run` | `swift run AbbeyBot serve …` | `swift run AbbeyBot cli`
        .executable(name: "AbbeyBot", targets: ["AbbeyEntry"])
    ],
    dependencies: [
        .package(url: "https://github.com/DiscordBM/DiscordBM", from: "1.16.0"),
        .package(url: "https://github.com/vapor/vapor", from: "4.115.0"),
        .package(url: "https://github.com/vapor/fluent", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver", from: "2.9.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver", from: "4.6.0"),
        .package(url: "https://github.com/vapor/leaf", from: "4.4.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "4.5.0")
    ],
    targets: packageTargets
)
