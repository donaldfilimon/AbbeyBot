// swift-tools-version: 6.4
import Foundation
import PackageDescription

/// When `ABBEY_PACKAGE_ROLE=server`, omit the SwiftUI/SwiftData desktop target so Linux
/// CI / Docker / swiftly can build the unified `AbbeyBot` executable without AppKit.
let serverOnlyPackage = ProcessInfo.processInfo.environment["ABBEY_PACKAGE_ROLE"] == "server"
/// Native Discord media dependencies are intentionally opt-in. The normal desktop/server
/// package graph must not require a locally bootstrapped C/C++ dependency prefix.
let nativeMediaEnabled = ProcessInfo.processInfo.environment["ABBEY_NATIVE_MEDIA"] == "1"
let nativeMediaPrefix = ProcessInfo.processInfo.environment["ABBEY_NATIVE_PREFIX"]
    ?? "\(ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp")/AbbeyBot.native/v1"

var packageTargets: [Target] = [
    .target(
        name: "AbbeyCore",
        dependencies: [
            .product(name: "DiscordBM", package: "DiscordBM"),
            .product(name: "WSClient", package: "swift-websocket"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto")
        ],
        path: "Sources/AbbeyCore",
        resources: [
            .copy("../../Contracts/Abbey"),
            .copy("Resources/KnowledgeSnapshot")
        ],
        swiftSettings: [
            .swiftLanguageMode(.v6)
        ]
    ),
    .target(
        name: "AbbeyServerKit",
        dependencies: [
            "AbbeyCore",
            "AbbeyQuasarKit",
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
        name: "AbbeyQuasarKit",
        dependencies: [
            "AbbeyCore",
            .product(name: "Crypto", package: "swift-crypto")
        ],
        path: "Sources/AbbeyQuasarKit",
        resources: [
            .copy("Resources/next-site"),
            .copy("Resources/next-site.manifest.json")
        ],
        swiftSettings: [
            .swiftLanguageMode(.v6)
        ]
    ),
    .target(
        name: "AbbeyServer",
        dependencies: [
            "AbbeyCore",
            "AbbeyQuasarKit",
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
        dependencies: [
            "AbbeyCore",
            // Real, in-process Discord Voice Gateway v8 WebSocket loopback server/client
            // fixtures (VoiceGatewayLoopbackWebSocketTests.swift) — exercises genuine WebSocket
            // handshake/framing over 127.0.0.1 instead of the in-process fake transport used by
            // VoiceGatewayClientTests.swift.
            .product(name: "WSClient", package: "swift-websocket"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto")
        ],
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
        name: "AbbeyQuasarKitTests",
        dependencies: ["AbbeyQuasarKit", "AbbeyCore"],
        path: "Tests/AbbeyQuasarKitTests",
        resources: [.copy("Fixtures")],
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
    "AbbeyQuasarKit",
    "AbbeyServer",
    "AbbeyCLI"
]

if nativeMediaEnabled {
    packageTargets.append(contentsOf: [
        .systemLibrary(
            name: "CLibDave",
            path: "Sources/CLibDave",
            pkgConfig: "libdave"
        ),
        .systemLibrary(
            name: "COpus",
            path: "Sources/COpus",
            pkgConfig: "opus"
        ),
        .systemLibrary(
            name: "CSodium",
            path: "Sources/CSodium",
            pkgConfig: "libsodium"
        ),
        .target(
            name: "AbbeyMediaNative",
            dependencies: ["AbbeyCore", "CLibDave", "COpus", "CSodium"],
            path: "Sources/AbbeyMediaNative",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                // The audited libdave archive is dynamic on Apple platforms. XCTest launchers
                // sanitize DYLD_LIBRARY_PATH, so embed the explicit opt-in prefix as an rpath.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "\(nativeMediaPrefix)/lib"])
            ]
        ),
        .testTarget(
            name: "AbbeyMediaNativeTests",
            dependencies: ["AbbeyMediaNative", "AbbeyCore"],
            path: "Tests/AbbeyMediaNativeTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ])
}

if !serverOnlyPackage {
    var desktopAppDependencies: [Target.Dependency] = ["AbbeyCore", "AbbeyQuasarKit", "AbbeyMediaMacOS"]
    if nativeMediaEnabled {
        desktopAppDependencies.append("AbbeyMediaNative")
    }
    packageTargets.append(
        .target(
            name: "AbbeyMediaMacOS",
            path: "Sources/AbbeyMediaMacOS",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AppKit")
            ]
        )
    )
    packageTargets.insert(
        .target(
            name: "AbbeyBotApp",
            dependencies: desktopAppDependencies,
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
            dependencies: ["AbbeyBotApp", "AbbeyMediaMacOS"],
            path: "Tests/AbbeyBotAppTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    )
    packageTargets.append(
        .testTarget(
            name: "AbbeyMediaMacOSTests",
            dependencies: ["AbbeyMediaMacOS"],
            path: "Tests/AbbeyMediaMacOSTests",
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

var packageProducts: [Product] = [
    .library(name: "AbbeyCore", targets: ["AbbeyCore"]),
    .library(name: "AbbeyQuasarKit", targets: ["AbbeyQuasarKit"]),
    .library(name: "AbbeyServerKit", targets: ["AbbeyServerKit"]),
    // Sole executable product -> bare `swift run` works (defaults to desktop on macOS).
    // Roles: `swift run` | `swift run AbbeyBot serve ...` | `swift run AbbeyBot cli`
    .executable(name: "AbbeyBot", targets: ["AbbeyEntry"])
]
if nativeMediaEnabled {
    packageProducts.append(.library(name: "AbbeyMediaNative", targets: ["AbbeyMediaNative"]))
}
if !serverOnlyPackage {
    packageProducts.append(.library(name: "AbbeyMediaMacOS", targets: ["AbbeyMediaMacOS"]))
}

let package = Package(
    name: "AbbeyBot",
    platforms: [
        .macOS(.v27),
        .driverKit(.v27)
    ],
    products: packageProducts,
    dependencies: [
        .package(url: "https://github.com/DiscordBM/DiscordBM", from: "1.16.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.3"),
        .package(url: "https://github.com/hummingbird-project/swift-websocket.git", from: "1.6.1"),
        .package(url: "https://github.com/vapor/vapor", from: "4.115.0"),
        .package(url: "https://github.com/vapor/fluent", from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver", from: "2.9.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver", from: "4.6.0"),
        .package(url: "https://github.com/vapor/leaf", from: "4.4.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "4.5.0")
    ],
    targets: packageTargets
)
