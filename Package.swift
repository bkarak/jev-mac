// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Jev",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "jev", targets: ["jev"]),
        .library(name: "JevCore", targets: ["JevCore"]),
    ],
    targets: [
        .target(name: "JevCore"),
        .executableTarget(name: "jev", dependencies: ["JevCore"]),
        .testTarget(name: "JevCoreTests", dependencies: ["JevCore"]),
    ]
)
