// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "jev-mac",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "jev-mac", targets: ["jev-mac"]),
        .library(name: "JevMac", targets: ["JevMac"]),
    ],
    targets: [
        .target(name: "JevMac"),
        .executableTarget(name: "jev-mac", dependencies: ["JevMac"]),
        .testTarget(name: "JevMacTests", dependencies: ["JevMac"]),
    ]
)
