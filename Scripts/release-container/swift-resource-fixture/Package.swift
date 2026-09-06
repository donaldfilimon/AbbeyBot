// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AbbeyResourceFixture",
    products: [.executable(name: "resource-probe", targets: ["ResourceProbe"])],
    targets: [
        .target(name: "ResourceLibrary", resources: [.copy("Resources/marker.txt")]),
        .executableTarget(name: "ResourceProbe", dependencies: ["ResourceLibrary"]),
    ]
)
